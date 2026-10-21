# Translates the OpenAI-shaped options Captain features send (a temperature, response_format: json_object,
# small max_tokens caps) into requests the Claude Messages API accepts.
class Llm::Providers::Anthropic::Protocol < RubyLLM::Protocols::Anthropic
  DEFAULT_MAX_TOKENS = 16_000
  OFFICIAL_API_HOST = 'api.anthropic.com'.freeze
  SERVER_SIDE_FALLBACK_BETA = 'server-side-fallback-2026-07-01'.freeze
  CONVERSATION_START = '[Conversation started]'.freeze
  # OpenAI's json_object mode guarantees valid JSON, so upstream prompts sometimes show loose examples like { notes: ['...'] }.
  JSON_OUTPUT_INSTRUCTION = 'Respond with a single valid JSON object only, without code fences or any text outside the JSON. ' \
                            'Use strict JSON syntax: double quotes around every key and string, even where an example above uses another notation. ' \
                            'If you need a tool, call it first and write the JSON once you have its results.'.freeze

  # Runs after RubyLLM merges provider options into the payload, which is where Captain's json_object format arrives.
  def render(messages, max_output_tokens: nil, **)
    payload = super(messages, max_output_tokens: max_output_tokens || [model.max_output_tokens, DEFAULT_MAX_TOKENS].compact.min, **)
    apply_model_constraints(payload)
    apply_claude_features(payload)
    apply_json_object_format(payload)

    schema = payload.dig(:output_config, :format, :schema)
    payload[:output_config][:format][:schema] = Llm::Providers::AnthropicSchema.transform(schema) if schema
    payload.merge(messages: normalize_messages(payload[:messages]))
  end

  private

  # Current Claude models reject sampling parameters, while Captain sends a temperature with most requests.
  def apply_model_constraints(payload)
    payload.delete(:temperature) if model.metadata[:temperature] == false
    return unless model.metadata[:adaptive_thinking]

    # Thinking is always on for these models and counts toward max_tokens, so a cap sized for the reply alone truncates it.
    payload[:max_tokens] = [payload[:max_tokens], DEFAULT_MAX_TOKENS].max
    return if config.anthropic_effort.blank?

    payload[:output_config] = RubyLLM::Support::Utils.deep_merge({ effort: config.anthropic_effort }, payload[:output_config].to_h)
  end

  def apply_claude_features(payload)
    # Automatic prompt caching pays off when the same prefix is re-sent, which a tool loop does on every step.
    payload[:cache_control] ||= { type: 'ephemeral' } if payload[:tools].present?
    # Retries a safety-classifier refusal on Anthropic's recommended fallback model; only the first-party API offers it.
    payload[:fallbacks] ||= 'default' if model.metadata[:server_side_fallback] && URI(provider.api_base).host == OFFICIAL_API_HOST
  end

  def apply_json_object_format(payload)
    return unless payload.dig(:response_format, :type) == 'json_object'

    payload.delete(:response_format)
    payload[:system] = Array(payload[:system]) + [{ type: 'text', text: JSON_OUTPUT_INSTRUCTION }]
  end

  # The Messages API rejects whitespace-only text blocks (image-only messages produce them) and a leading assistant turn.
  def normalize_messages(messages)
    messages = messages.filter_map do |message|
      content = message[:content].reject { |block| block[:type] == 'text' && block[:text].blank? }
      message.merge(content: content) if content.any?
    end
    return messages unless messages.first[:role] == 'assistant'

    [{ role: 'user', content: [{ type: 'text', text: CONVERSATION_START }] }, *messages]
  end

  def sync_response(payload, additional_headers = {})
    super(payload, fallback_headers(payload, additional_headers))
  end

  def stream_response(payload, additional_headers = {}, &)
    super(payload, fallback_headers(payload, additional_headers), &)
  end

  def fallback_headers(payload, headers)
    return headers unless payload[:fallbacks]

    headers.merge('anthropic-beta' => join_betas(headers['anthropic-beta'], SERVER_SIDE_FALLBACK_BETA))
  end

  def parse_completion_response(response)
    if response.body['stop_reason'] == 'refusal'
      category = response.body.dig('stop_details', 'category')
      raise Llm::Providers::Anthropic::RefusalError.new("Claude declined the request#{" (#{category})" if category}", response: response)
    end

    super
  end
end
