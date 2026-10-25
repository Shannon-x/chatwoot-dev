# Translates the OpenAI-shaped options Captain features send (a temperature, response_format: json_object,
# small max_tokens caps) into requests the Claude Messages API accepts.
class Llm::Providers::Anthropic::Protocol < RubyLLM::Protocols::Anthropic
  DEFAULT_MAX_TOKENS = 16_000
  OFFICIAL_API_HOST = 'api.anthropic.com'.freeze
  SERVER_SIDE_FALLBACK_BETA = 'server-side-fallback-2026-07-01'.freeze
  THINKING_BINDING_BETA = 'thinking-binding-controls-2026-08-01'.freeze
  THINKING_BLOCK_TYPES = %w[thinking redacted_thinking].freeze
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
    apply_thinking_replay(payload)

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

  # Claude 5 models bind each thinking block to the system prompt, tools and earlier messages it was produced under, and
  # reject a replay under a different prefix with a 400 that no retry clears. Captain V2 hands conversations between agents
  # with their own instructions and tools, so the previous agent's blocks stop matching; drop_block lets the API discard
  # those and keep the rest. A model running without thinking only sees such blocks after a model switch, so they go.
  def apply_thinking_replay(payload)
    return unless payload[:messages].any? { |message| replays_thinking?(message) }
    return bind_replayed_thinking(payload) if model.metadata[:adaptive_thinking]

    strip_replayed_thinking(payload) unless thinking_on?(payload)
  end

  def bind_replayed_thinking(payload)
    payload[:thinking] = (payload[:thinking] || { type: 'adaptive' }).merge(block_binding: { prefix_mismatch_behavior: 'drop_block' })
  end

  def strip_replayed_thinking(payload)
    payload[:messages] = payload[:messages].map { |message| message.merge(content: message[:content].reject { |block| thinking_block?(block) }) }
  end

  def thinking_on?(payload)
    payload[:thinking].present? && payload[:thinking][:type] != 'disabled'
  end

  def replays_thinking?(message)
    message[:role] == 'assistant' && message[:content].any? { |block| thinking_block?(block) }
  end

  # RubyLLM replays the blocks it parsed from a response with string keys and rebuilds restored history with symbol keys.
  def thinking_block?(block)
    THINKING_BLOCK_TYPES.include?(block[:type] || block['type'])
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
    super(payload, beta_headers(payload, additional_headers))
  end

  def stream_response(payload, additional_headers = {}, &)
    super(payload, beta_headers(payload, additional_headers), &)
  end

  def beta_headers(payload, headers)
    betas = []
    betas << SERVER_SIDE_FALLBACK_BETA if payload[:fallbacks]
    betas << THINKING_BINDING_BETA if payload.dig(:thinking, :block_binding)
    betas.reduce(headers) { |merged, beta| merged.merge('anthropic-beta' => join_betas(merged['anthropic-beta'], beta)) }
  end

  def parse_completion_response(response)
    if response.body['stop_reason'] == 'refusal'
      category = response.body.dig('stop_details', 'category')
      raise Llm::Providers::Anthropic::RefusalError.new("Claude declined the request#{" (#{category})" if category}", response: response)
    end
    log_dropped_thinking(response.body['input_transformations'])

    super
  end

  def log_dropped_thinking(transformations)
    return if transformations.blank?

    dropped = transformations.map { |change| "#{change['path']} (#{change['reason']})" }.join(', ')
    Rails.logger.info("[Llm::Providers::Anthropic] Claude dropped replayed thinking blocks: #{dropped}")
  end
end
