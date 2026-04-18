module Llm::Models
  CONFIG = YAML.load_file(Rails.root.join('config/llm.yml')).freeze

  class << self
    def providers = CONFIG['providers']
    def models = CONFIG['models']
    def features = CONFIG['features']
    def feature_keys = CONFIG['features'].keys

    def default_model_for(feature)
      CONFIG.dig('features', feature.to_s, 'default')
    end

    def models_for(feature)
      CONFIG.dig('features', feature.to_s, 'models') || []
    end

    def valid_model_for?(feature, model_name)
      return true if models_for(feature).include?(model_name.to_s)

      # Allow any model whose name matches a known OpenAI prefix so that newly
      # released models (e.g. gpt-5.5-2026-xx-xx) work without editing llm.yml.
      openai_prefixes = LlmConstants::PROVIDER_PREFIXES['openai']
      openai_prefixes.any? { |prefix| model_name.to_s.start_with?(prefix) }
    end

    def feature_config(feature_key)
      feature = features[feature_key.to_s]
      return nil unless feature

      {
        models: feature['models'].filter_map do |model_name|
          model = models[model_name]
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
