require 'ruby_llm'

module Llm::Config
  DEFAULT_MODEL = 'gpt-4.1-mini'.freeze

  # Ordered list of candidate paths for the custom model registry.
  # The first path that resolves to an existing file wins.
  DEFAULT_MODEL_REGISTRY_PATHS = [
    -> { ENV['RUBYLLM_MODEL_REGISTRY_FILE'].presence },
    -> { Rails.root.join('config', 'llm_models.json').to_s },
    -> { Rails.root.join('llm_models.json').to_s }
  ].freeze

  class << self
    def initialized?
      @initialized ||= false
    end

    def initialize!
      return if @initialized

      configure_ruby_llm
      @initialized = true
    end

    def reset!
      @initialized = false
    end

    def with_api_key(api_key, api_base: nil)
      initialize!
      context = RubyLLM.context do |config|
        config.openai_api_key = api_key
        config.openai_api_base = api_base
        # Always point every context at our registry so new models are recognized
        # regardless of when the global singleton was first created.
        config.model_registry_file = custom_model_registry_file if custom_model_registry_file
      end

      yield context
    end

    private

    def configure_ruby_llm
      RubyLLM.configure do |config|
        config.openai_api_key = system_api_key if system_api_key.present?
        config.openai_api_base = LlmConstants.api_base_with_version(openai_endpoint) if openai_endpoint.present?
        config.model_registry_file = custom_model_registry_file if custom_model_registry_file
        config.logger = Rails.logger
      end

      # Force the global Models singleton to reload from our registry file.
      # RubyLLM may have auto-created the singleton from the gem's bundled
      # models.json before configure ran, so we replace it explicitly here.
      RubyLLM.models.load_from_json!(custom_model_registry_file) if custom_model_registry_file
    end

    # Returns the first existing path from DEFAULT_MODEL_REGISTRY_PATHS,
    # or nil if none of the candidates exist.
    def custom_model_registry_file
      @custom_model_registry_file ||= DEFAULT_MODEL_REGISTRY_PATHS
                                      .filter_map(&:call)
                                      .find { |path| File.exist?(path) }
    end

    def system_api_key
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value
    end

    def openai_endpoint
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value
    end
  end
end
