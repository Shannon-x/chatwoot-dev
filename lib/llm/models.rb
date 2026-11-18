module Llm::Models
  CONFIG = YAML.load_file(Rails.root.join('config/llm.yml')).freeze
  RETIRED_TEXT_MODELS = %w[
    gpt-5 gpt-5-2025-08-07 gpt-5-mini gpt-5-mini-2025-08-07 gpt-5-nano gpt-5-nano-2025-08-07
    gpt-5-pro gpt-5-pro-2025-10-06 o3 o3-2025-04-16 o3-pro o3-pro-2025-06-10
    gpt-5.4-nano gpt-5.4-nano-2026-03-17
  ].freeze
  RETIRED_TRANSCRIPTION_MODELS = %w[gpt-4o-mini-transcribe whisper-1].freeze

  class << self
    def providers = CONFIG.fetch('providers')
    def models = CONFIG.fetch('models')
    def features = CONFIG.fetch('features')
    def feature_keys = features.reject { |_key, config| config['internal'] }.keys
    def internal_feature_keys = features.select { |_key, config| config['internal'] }.keys
    def model_feature_keys = features.keys

    def internal_feature?(feature)
      features.dig(feature.to_s, 'internal') == true
    end

    def feature?(feature)
      features.key?(feature.to_s)
    end

    def default_model_for(feature)
      features.dig(feature.to_s, 'default')
    end

    def models_for(feature)
      features.dig(feature.to_s, 'models') || []
    end

    def replacement_for_retired_model(model)
      return default_model_for('audio_transcription') if RETIRED_TRANSCRIPTION_MODELS.include?(model)
      return default_model_for('conversation_completion') if model.to_s.start_with?('gpt-4') || RETIRED_TEXT_MODELS.include?(model)
    end

    def valid_model_for?(feature, model_name)
      return true if models_for(feature).include?(model_name.to_s)
      return false if replacement_for_retired_model(model_name)

      # Allow any model whose name matches a known OpenAI prefix so that newly
      # released models (e.g. gpt-5.5-2026-xx-xx) work without editing llm.yml.
      openai_prefixes = LlmConstants::PROVIDER_PREFIXES['openai']
      openai_prefixes.any? { |prefix| model_name.to_s.start_with?(prefix) }
    end

    def model_config(model_name)
      models[model_name.to_s]
    end

    def provider_for(model_name)
      model_config(model_name)&.dig('provider')
    end

    # config/llm.yml can override the registry, which `rake ruby_llm:refresh_models` regenerates.
    def temperature_for(model_name, temperature)
      supported = model_config(model_name)&.dig('temperature')
      supported = RubyLLM.models.find(model_name).metadata[:temperature] if supported.nil?
      temperature unless supported == false
    end

    def feature_config(feature_key)
      feature = features[feature_key.to_s]
      return nil unless feature

      {
        models: models_for(feature_key).filter_map do |model_name|
          model = model_config(model_name)
          next unless model # skip entries not present in the models section

          {
            id: model_name,
            display_name: model['display_name'],
            provider: model['provider'],
            coming_soon: model['coming_soon'],
            credit_multiplier: model['credit_multiplier']
          }
        end,
        default: feature['default']
      }
    end
  end
end
