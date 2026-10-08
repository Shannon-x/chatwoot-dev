require 'rails_helper'

RSpec.describe Llm::Providers::Anthropic do
  let(:messages_url) { 'https://api.anthropic.com/v1/messages' }
  let(:api_base) { 'https://api.anthropic.com' }
  let(:effort) { nil }
  let(:context) do
    RubyLLM.context do |config|
      config.anthropic_api_key = 'test-key'
      config.anthropic_api_base = api_base
      config.anthropic_effort = effort
    end
  end
  let(:text_response) do
    {
      id: 'msg_1', type: 'message', role: 'assistant', model: 'claude-sonnet-5-5',
      content: [{ type: 'thinking', thinking: '', signature: 'sig' }, { type: 'text', text: '{"answer":"ok"}' }],
      stop_reason: 'end_turn', usage: { input_tokens: 10, output_tokens: 5 }
    }
  end
  let(:responses) { [text_response] }
  let(:requests) { [] }

  before do
    Llm::Config.initialize!
    stub_request(:post, messages_url).to_return do |request|
      requests << { body: JSON.parse(request.body), headers: request.headers }
      { status: 200, body: responses.shift.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
  end

  it 'is the provider RubyLLM resolves Claude models to' do
    expect(context.chat(model: 'claude-sonnet-5-5').instance_variable_get(:@provider)).to be_a(described_class)
  end

  it 'translates OpenAI-style options into a valid Messages API request' do
    response = context.chat(model: 'claude-sonnet-5-5')
                      .with_temperature(1.0)
                      .with_params(response_format: { type: 'json_object' }, max_tokens: 1000)
                      .with_instructions('You are Captain.')
                      .ask('Hello')

    body = requests.first[:body]
    expect(response.content).to eq('{"answer":"ok"}')
    expect(body).not_to include('temperature', 'response_format')
    expect(body['max_tokens']).to eq(described_class::DEFAULT_MAX_TOKENS)
    expect(body['system'].pluck('text')).to eq(['You are Captain.', described_class::JSON_OUTPUT_INSTRUCTION])
    expect(body['fallbacks']).to eq('default')
    expect(requests.first[:headers]['Anthropic-Beta']).to eq(described_class::SERVER_SIDE_FALLBACK_BETA)
  end

  context 'with an effort configured' do
    let(:effort) { 'low' }

    it 'sends it as output_config.effort' do
      context.chat(model: 'claude-haiku-5-5').ask('Hello')

      expect(requests.first[:body]['output_config']).to eq('effort' => 'low')
    end
  end

  it 'leaves out server-side fallback for models without it' do
    context.chat(model: 'claude-haiku-5-5').ask('Hello')

    expect(requests.first[:body]).not_to include('fallbacks')
    expect(requests.first[:headers]).not_to include('Anthropic-Beta')
  end

  context 'with a custom endpoint' do
    let(:api_base) { 'https://llm-gateway.example.com' }
    let(:messages_url) { 'https://llm-gateway.example.com/v1/messages' }

    it 'leaves out server-side fallback' do
      context.chat(model: 'claude-opus-5-5').ask('Hello')

      expect(requests.first[:body]).not_to include('fallbacks')
    end
  end

  it 'makes the history valid for the Messages API' do
    chat = context.chat(model: 'claude-sonnet-5-5')
    chat.add_message(role: :assistant, content: 'Hi, how can I help?')
    chat.add_message(role: :user, content: RubyLLM::Content.new('', 'https://example.com/photo.png'))
    chat.ask('What is in this photo?')

    messages = requests.first[:body]['messages']
    expect(messages.pluck('role')).to eq(%w[user assistant user user])
    expect(messages.first['content']).to eq([{ 'type' => 'text', 'text' => described_class::CONVERSATION_START }])
    expect(messages.third['content'].pluck('type')).to eq(['image'])
  end

  it 'adapts structured output schemas to what Claude accepts' do
    schema = {
      type: 'object',
      properties: {
        text: { type: 'string', minLength: 1 },
        indexes: { type: 'array', minItems: 2, items: { type: 'integer', minimum: 1 } }
      },
      required: %w[text indexes]
    }
    context.chat(model: 'claude-sonnet-5-5').with_schema(schema).ask('Hello')

    expect(requests.first[:body].dig('output_config', 'format', 'schema')).to eq(
      'type' => 'object',
      'properties' => {
        'text' => { 'type' => 'string', 'description' => '{minLength: 1}' },
        'indexes' => {
          'type' => 'array',
          'items' => { 'type' => 'integer', 'description' => '{minimum: 1}' },
          'description' => '{minItems: 2}'
        }
      },
      'additionalProperties' => false,
      'required' => %w[text indexes]
    )
  end

  context 'when Claude calls tools in parallel' do
    let(:responses) do
      [
        {
          id: 'msg_1', type: 'message', role: 'assistant', model: 'claude-sonnet-5-5',
          content: [
            { type: 'tool_use', id: 'toolu_1', name: 'weather', input: { city: 'Paris' } },
            { type: 'tool_use', id: 'toolu_2', name: 'weather', input: { city: 'Rome' } }
          ],
          stop_reason: 'tool_use', usage: { input_tokens: 10, output_tokens: 5 }
        },
        text_response
      ]
    end

    before do
      stub_const('WeatherTool', Class.new(RubyLLM::Tool) do
        description 'Looks up the weather'
        param :city, desc: 'City name'

        def execute(city:)
          "Sunny in #{city}"
        end
      end)
    end

    it 'returns all tool results in one user turn and caches the prefix' do
      context.chat(model: 'claude-sonnet-5-5').with_tool(WeatherTool).ask('Weather in Paris and Rome?')

      follow_up = requests.second[:body]
      expect(follow_up['cache_control']).to eq('type' => 'ephemeral')
      expect(follow_up['messages'].pluck('role')).to eq(%w[user assistant user])
      expect(follow_up['messages'].last['content'].pluck('tool_use_id', 'content')).to eq(
        [['toolu_1', [{ 'type' => 'text', 'text' => 'Sunny in Paris' }]], ['toolu_2', [{ 'type' => 'text', 'text' => 'Sunny in Rome' }]]]
      )
    end
  end

  context 'when Claude declines the request' do
    let(:responses) do
      [{
        id: 'msg_1', type: 'message', role: 'assistant', model: 'claude-sonnet-5-5', content: [],
        stop_reason: 'refusal', stop_details: { category: 'cyber' }, usage: { input_tokens: 10, output_tokens: 0 }
      }]
    end

    it 'raises instead of returning an empty reply' do
      expect { context.chat(model: 'claude-sonnet-5-5').ask('Hello') }
        .to raise_error(described_class::RefusalError, 'Claude declined the request (cyber)')
    end
  end
end
