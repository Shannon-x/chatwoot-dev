require 'ruby_llm'

module Llm::Config
  DEFAULT_MODEL = 'gpt-4.1-mini'.freeze

  class << self
    def initialized?
      @initialized ||= false
    end

    def initialize!
      return if @initialized

      configure_ruby_llm
      # Force the global Models singleton to use our llm_models.json.
      # RubyLLM may have auto-created the singleton from its bundled registry
      # before we ran configure, so we explicitly reload it here.
      RubyLLM::Models.instance.load_from_json!(Rails.root.join('config/llm_models.json').to_s)
      @initialized = true
    end

    def reset!
      @initialized = false
    end

    def with_api_key(api_key, api_base: nil)
      initialize!
      registry_file = Rails.root.join('config/llm_models.json').to_s
      context = RubyLLM.context do |config|
        config.openai_api_key = api_key
        config.openai_api_base = api_base
        # Explicitly set in every context so new models in our llm_models.json
        # are always used regardless of when the global singleton was initialized.
        config.model_registry_file = registry_file
      end

      yield context
    end

    private

    def configure_ruby_llm
      RubyLLM.configure do |config|
        config.openai_api_key = system_api_key if system_api_key.present?
        config.openai_api_base = LlmConstants.api_base_with_version(openai_endpoint) if openai_endpoint.present?
        config.model_registry_file = Rails.root.join('config/llm_models.json').to_s
        config.logger = Rails.logger
      end
    end

    def system_api_key
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value
    end

    def openai_endpoint
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value
    end
  end
end
