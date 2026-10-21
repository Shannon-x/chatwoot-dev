# Claude provider for Captain, registered over RubyLLM's built-in Anthropic provider
# (config/initializers/ruby_llm.rb) so every RubyLLM chat that resolves to a Claude model goes through it.
#
# Its protocol (lib/llm/providers/anthropic/protocol.rb) adapts the OpenAI-shaped options Captain features send,
# so features added upstream keep working when an account picks a Claude model, without per-feature changes.
class Llm::Providers::Anthropic < RubyLLM::Providers::Anthropic
  class RefusalError < RubyLLM::Error; end

  # Protocols are declared per provider class, so the built-in Anthropic ones are not inherited.
  protocol :anthropic, Protocol, batches: RubyLLM::Protocols::Anthropic::Batches
  protocol :files, RubyLLM::Protocols::Anthropic::Files

  def self.configuration_options
    super + %i[anthropic_effort]
  end
end
