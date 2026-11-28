require 'rails_helper'

RSpec.describe Llm::Config do
  describe '.load_model_registry' do
    it 'applies Captain metadata to matching Anthropic models and adds models missing from the registry' do
      registry = RubyLLM::Models.new([])
      allow(RubyLLM).to receive(:models).and_return(registry)
      sonnet = { id: 'claude-sonnet-5-5', provider: 'anthropic', context_window: 123_456 }

      Tempfile.create('captain-models') do |file|
        file.write([sonnet, sonnet.merge(provider: 'bedrock')].to_json)
        file.flush
        allow(described_class).to receive(:custom_model_registry_file).and_return(file.path)
        described_class.send(:load_model_registry)

        model = registry.find('claude-sonnet-5-5', provider: :anthropic)
        expect(model.context_window).to eq(123_456)
        expect(model.metadata).to include(adaptive_thinking: true, server_side_fallback: true)
        expect(registry.find('claude-sonnet-5-5', provider: :bedrock).metadata).not_to have_key(:adaptive_thinking)
        expect(registry.find('claude-haiku-5-5', provider: :anthropic).metadata).to include(server_side_fallback: false)
        expect(registry.by_provider(:anthropic).map(&:id)).to contain_exactly('claude-sonnet-5-5', 'claude-opus-5-5', 'claude-haiku-5-5')
      end
    end
  end

  describe '.configure_ruby_llm' do
    it 'adds the API version to the configured OpenAI endpoint' do
      original_base = RubyLLM.config.openai_api_base
      InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT').update!(value: 'https://example.test/')

      described_class.send(:configure_ruby_llm)

      expect(RubyLLM.config.openai_api_base).to eq('https://example.test/v1')
    ensure
      RubyLLM.configure { |config| config.openai_api_base = original_base }
    end
  end
end
