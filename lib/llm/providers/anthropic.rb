# Claude provider for Captain, registered over RubyLLM's built-in Anthropic provider
# (config/initializers/ruby_llm.rb) so every RubyLLM chat that resolves to a Claude model goes through it.
#
# Captain features call RubyLLM with OpenAI-shaped options: a temperature, response_format: json_object,
# small max_tokens caps. This class translates those into requests the Claude Messages API accepts, so
# features added upstream keep working when an account picks a Claude model, without per-feature changes.
class Llm::Providers::Anthropic < RubyLLM::Providers::Anthropic
  class RefusalError < RubyLLM::Error; end

  DEFAULT_MAX_TOKENS = 16_000
  OFFICIAL_API_HOST = 'api.anthropic.com'.freeze
  SERVER_SIDE_FALLBACK_BETA = 'server-side-fallback-2026-07-01'.freeze
  CONVERSATION_START = '[Conversation started]'.freeze
  JSON_OUTPUT_INSTRUCTION = 'Respond with a single valid JSON object only, without code fences or any text outside the JSON. ' \
                            'If you need a tool, call it first and write the JSON once you have its results.'.freeze

  def self.configuration_options
    super + %i[anthropic_effort]
  end

  # rubocop:disable Metrics/ParameterLists
  def complete(messages, tools:, model:, params: {}, headers: {}, **, &)
    params = RubyLLM::Utils.deep_merge(default_params(model, tools), params)
    # Thinking is always on for these models and counts toward max_tokens, so a cap sized for the reply alone truncates it.
    params[:max_tokens] = [params[:max_tokens], DEFAULT_MAX_TOKENS].max if model.metadata[:adaptive_thinking]
    headers = headers.merge('anthropic-beta' => SERVER_SIDE_FALLBACK_BETA) if params[:fallbacks]

    super(messages, tools: tools, model: model, params: params, headers: headers, **, &)
  end
  # rubocop:enable Metrics/ParameterLists

  private

  def default_params(model, tools)
    {
      max_tokens: [model.max_tokens, DEFAULT_MAX_TOKENS].compact.min,
      output_config: ({ effort: @config.anthropic_effort } if model.metadata[:adaptive_thinking] && @config.anthropic_effort.present?),
      # Automatic prompt caching pays off when the same prefix is re-sent, which a tool loop does on every step.
      cache_control: ({ type: 'ephemeral' } if tools.any?),
      # Retries a safety-classifier refusal on Anthropic's recommended fallback model; only the first-party API offers it.
      fallbacks: ('default' if model.metadata[:server_side_fallback] && URI(api_base).host == OFFICIAL_API_HOST)
    }.compact
  end

  # Current Claude models reject sampling parameters, while Captain sends a temperature with most requests.
  def maybe_normalize_temperature(temperature, model)
    temperature unless model.metadata[:temperature] == false
  end

  def sync_response(connection, payload, additional_headers = {})
    super(connection, normalize_payload(payload), additional_headers)
  end

  def stream_response(connection, payload, additional_headers = {}, &)
    super(connection, normalize_payload(payload), additional_headers, &)
  end

  def parse_completion_response(response)
    if response.body['stop_reason'] == 'refusal'
      category = response.body.dig('stop_details', 'category')
      raise RefusalError.new(response, "Claude declined the request#{" (#{category})" if category}")
    end

    super
  end

  def normalize_payload(payload)
    if payload.dig(:response_format, :type) == 'json_object'
      payload.delete(:response_format)
      payload[:system] = Array(payload[:system]) + [{ type: 'text', text: JSON_OUTPUT_INSTRUCTION }]
    end

    schema = payload.dig(:output_config, :format, :schema)
    payload[:output_config][:format][:schema] = Llm::Providers::AnthropicSchema.transform(schema) if schema
    payload.merge(messages: normalize_messages(payload[:messages]))
  end

  # The Messages API rejects empty text blocks (image-only messages produce them) and a leading
  # assistant turn, and expects parallel tool results in one user turn while RubyLLM sends one per result.
  def normalize_messages(messages)
    messages = messages.filter_map do |message|
      content = message[:content].reject { |block| block[:type] == 'text' && block[:text].blank? }
      message.merge(content: content) if content.any?
    end
    messages = merge_tool_results(messages)
    return messages unless messages.first[:role] == 'assistant'

    [{ role: 'user', content: [{ type: 'text', text: CONVERSATION_START }] }, *messages]
  end

  def merge_tool_results(messages)
    messages.each_with_object([]) do |message, merged|
      if tool_results?(message) && merged.last && tool_results?(merged.last)
        merged[-1] = merged.last.merge(content: merged.last[:content] + message[:content])
      else
        merged << message
      end
    end
  end

  def tool_results?(message)
    message[:role] == 'user' && message[:content].all? { |block| block[:type] == 'tool_result' }
  end
end
