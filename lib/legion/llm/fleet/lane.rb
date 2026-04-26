# frozen_string_literal: true

require 'digest'
require 'json'

module Legion
  module LLM
    module Fleet
      # Builds canonical RabbitMQ routing keys for shared fleet work lanes.
      module Lane
        FORBIDDEN_DIGEST_KEYS = %i[
          api_key authorization caller credential credentials endpoint endpoint_url
          filesystem identity messages path prompt reply_to secret secrets token url
        ].freeze

        module_function

        def routing_key(operation:, model:, context_window: nil, boundary: nil, eligibility_fingerprint: nil)
          parts = ['llm', 'fleet', operation_slug(operation), sanitize_model(model)]
          parts << "ctx#{Integer(context_window)}" if inference?(operation) && context_window
          parts.push('boundary', sanitize_segment(boundary)) if boundary
          parts.push('elig', sanitize_segment(eligibility_fingerprint)) if eligibility_fingerprint
          parts.join('.')
        end

        def offering_key(instance_id:, model:, operation:)
          [
            'llm',
            'fleet',
            'offering',
            sanitize_segment(instance_id),
            sanitize_model(model),
            operation_slug(operation)
          ].join('.')
        end

        def eligibility_fingerprint(facts)
          normalized = normalize_facts(facts)
          forbidden = forbidden_keys(normalized)
          raise ArgumentError, "eligibility facts include sensitive keys: #{forbidden.join(', ')}" if forbidden.any?

          Digest::SHA256.hexdigest(::JSON.generate(normalized))[0, 16]
        end

        def operation_slug(operation)
          case operation.to_s
          when 'embed', 'embedding', 'embeddings'
            'embed'
          else
            'inference'
          end
        end

        def inference?(operation)
          operation_slug(operation) == 'inference'
        end

        def sanitize_model(model)
          sanitize_segment(model).tr('.', '-')
        end

        def sanitize_segment(value)
          value.to_s.downcase
               .gsub(/[^a-z0-9]+/, '-')
               .gsub(/\A-+|-+\z/, '')
               .squeeze('-')
        end

        def normalize_facts(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, val), normalized|
              normalized[key.to_s] = normalize_facts(val)
            end.sort.to_h
          when Array
            value.map { |entry| normalize_facts(entry) }.sort_by(&:to_s)
          when Symbol
            value.to_s
          else
            value
          end
        end

        def forbidden_keys(value, path = [])
          return [] unless value.is_a?(Hash)

          value.flat_map do |key, val|
            key_path = path + [key]
            matches = FORBIDDEN_DIGEST_KEYS.include?(key.to_s.to_sym) ? [key_path.join('.')] : []
            matches + forbidden_keys(val, key_path)
          end
        end
      end
    end
  end
end
