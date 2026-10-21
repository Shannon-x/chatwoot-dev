# frozen_string_literal: true

require 'agents'

Rails.application.config.after_initialize do
  api_key = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value
  anthropic_api_key = InstallationConfig.find_by(name: 'CAPTAIN_ANTHROPIC_API_KEY')&.value
  model = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence || LlmConstants::DEFAULT_MODEL

  Agents.configure do |config|
    if api_key.present?
      config.openai_api_key = api_key
      config.openai_api_base = LlmConstants.api_base_with_version
    end
    config.default_model = model
    config.openai_protocol = :chat_completions
    config.model_registry_file = Rails.root.join('config/llm_models.json').to_s
    config.debug = false
  end

  # Agent runs use the global RubyLLM config, so load the Anthropic settings and Claude model registry up front.
  Llm::Config.initialize! if api_key.present? || anthropic_api_key.present?
rescue StandardError => e
  Rails.logger.error "Failed to configure AI Agents SDK: #{e.message}"
end
