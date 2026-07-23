# frozen_string_literal: true

module LlmConstants
  DEFAULT_MODEL = 'gpt-5.4-nano-2026-03-17'
  DEFAULT_EMBEDDING_MODEL = 'text-embedding-3-small'
  PDF_PROCESSING_MODEL = 'gpt-5.4-nano-2026-03-17'

  OPENAI_API_ENDPOINT = 'https://api.openai.com'

  # Strips any trailing /v1 (and slashes) from a raw endpoint string,
  # returning a "bare" base like https://api.sufe.pro
  # Accepts either an explicit value or reads from InstallationConfig.
  def self.normalized_api_base(raw_endpoint = nil)
    endpoint = raw_endpoint.presence ||
               InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value.presence
    return nil unless endpoint

    endpoint = endpoint.strip.chomp('/')
    endpoint = endpoint.chomp('/v1').chomp('/')
    endpoint
  end

  # Returns normalized base + /v1 — the format expected by RubyLLM, ai-agents and ruby-openai.
  def self.api_base_with_version(raw_endpoint = nil)
    base = normalized_api_base(raw_endpoint) || OPENAI_API_ENDPOINT
    "#{base}/v1"
  end

  PROVIDER_PREFIXES = {
    'openai' => %w[gpt- o1 o3 o4 codex- text-embedding- whisper- tts-],
    'anthropic' => %w[claude-],
    'google' => %w[gemini-],
    'mistral' => %w[mistral- codestral-],
    'deepseek' => %w[deepseek-]
  }.freeze
end
