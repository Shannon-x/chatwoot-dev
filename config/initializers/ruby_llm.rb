# frozen_string_literal: true

# Claude models resolve to Captain's provider, which adapts RubyLLM's Anthropic integration to the
# current Claude API (lib/llm/providers/anthropic.rb). Re-registered on every reload in development.
Rails.application.config.to_prepare do
  RubyLLM::Provider.register(:anthropic, Llm::Providers::Anthropic)
end
