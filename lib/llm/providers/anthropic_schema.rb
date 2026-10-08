# Rewrites a JSON schema into the subset Claude structured outputs accept, the same way the official
# Anthropic SDKs do: objects get additionalProperties: false, and constraints the API rejects
# (minLength, minimum, unsupported formats, ...) move into the description so the model still follows them.
module Llm::Providers::AnthropicSchema
  SUPPORTED_STRING_FORMATS = %w[date-time time date duration email hostname uri ipv4 ipv6 uuid].freeze
  PASSTHROUGH_KEYS = %w[type description title enum const].freeze

  class << self
    def transform(schema)
      transform_node(schema.deep_stringify_keys)
    end

    private

    def transform_node(node)
      return node.slice('$ref') if node.key?('$ref')

      result = node.extract!(*PASSTHROUGH_KEYS)
      result['$defs'] = node.delete('$defs').transform_values { |definition| transform_node(definition) } if node.key?('$defs')
      transform_combinators(node, result)
      transform_type_keywords(node, result)
      append_constraints(result, node) if node.any?
      result
    end

    def transform_combinators(node, result)
      any_of = node.delete('anyOf')
      one_of = node.delete('oneOf')
      all_of = node.delete('allOf')
      result['anyOf'] = (any_of || one_of).map { |variant| transform_node(variant) } if any_of || one_of
      result['allOf'] = all_of.map { |variant| transform_node(variant) } if all_of
    end

    def transform_type_keywords(node, result)
      case result['type']
      when 'object' then transform_object(node, result)
      when 'array' then transform_array(node, result)
      when 'string' then transform_string(node, result)
      end
    end

    def transform_object(node, result)
      result['properties'] = node.delete('properties').to_h.transform_values { |property| transform_node(property) }
      node.delete('additionalProperties')
      result['additionalProperties'] = false
      result['required'] = node.delete('required') if node.key?('required')
    end

    def transform_array(node, result)
      result['items'] = transform_node(node.delete('items')) if node.key?('items')
      result['minItems'] = node.delete('minItems') if [0, 1].include?(node['minItems'])
    end

    def transform_string(node, result)
      result['format'] = node.delete('format') if SUPPORTED_STRING_FORMATS.include?(node['format'])
    end

    def append_constraints(result, constraints)
      note = "{#{constraints.map { |key, value| "#{key}: #{value.to_json}" }.join(', ')}}"
      result['description'] = [result['description'], note].compact.join("\n\n")
    end
  end
end
