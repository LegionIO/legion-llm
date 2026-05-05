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
        FORBIDDEN_DIGEST_KEY_PATTERN = /
          (?:^|[^a-z0-9])
          (?:api[-_]?key|key|token|secret|credential|password|passphrase|auth|authorization|
             cookie|bearer|session|private[-_]?key|client[-_]?secret|refresh[-_]?token|
             access[-_]?token|signature|jwt|pat)
          (?:$|[^a-z0-9])
        /ix
        MAX_PUBLIC_SEGMENT_LENGTH = 64

        module_function

        def routing_key(operation:, model:, context_window: nil, boundary: nil, eligibility_fingerprint: nil)
          parts = ['llm', 'fleet', operation_slug(operation), sanitize_model(model)]
          parts << "ctx#{Integer(context_window)}" if inference?(operation) && context_window
          parts.push('boundary', public_segment(:boundary, boundary)) if boundary
          parts.push('elig', public_segment(:eligibility_fingerprint, eligibility_fingerprint)) if eligibility_fingerprint
          parts.join('.')
        end

        def offering_key(instance_id:, model:, operation:)
          [
            'llm',
            'fleet',
            'offering',
            public_segment(:instance_id, instance_id),
            sanitize_model(model),
            operation_slug(operation)
          ].join('.')
        end

        def eligibility_fingerprint(facts)
          normalized = normalize_facts(facts)
          forbidden = forbidden_keys(normalized)
          raise ArgumentError, "eligibility facts include sensitive keys: #{forbidden.join(', ')}" if forbidden.any?

          Digest::SHA256.hexdigest(Legion::JSON.generate(normalized))[0, 16]
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
          output = +''
          previous_dash = true
          value.to_s.downcase.each_byte do |byte|
            if byte.between?(97, 122) || byte.between?(48, 57)
              output << byte
              previous_dash = false
            elsif !previous_dash
              output << '-'
              previous_dash = true
            end
          end
          output.chop! if output.end_with?('-')
          output
        end

        def public_segment(label, value)
          raise ArgumentError, "#{label} contains sensitive content" if sensitive_segment?(value)

          segment = sanitize_segment(value)
          raise ArgumentError, "#{label} is empty after sanitization" if segment.empty?
          raise ArgumentError, "#{label} exceeds #{MAX_PUBLIC_SEGMENT_LENGTH} characters" if segment.length > MAX_PUBLIC_SEGMENT_LENGTH

          segment
        end

        def sensitive_segment?(value)
          value.to_s.match?(FORBIDDEN_DIGEST_KEY_PATTERN)
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
            matches = forbidden_digest_key?(key) ? [key_path.join('.')] : []
            matches + forbidden_keys(val, key_path)
          end
        end

        def forbidden_digest_key?(key)
          FORBIDDEN_DIGEST_KEYS.include?(key.to_s.downcase.to_sym) ||
            key.to_s.match?(FORBIDDEN_DIGEST_KEY_PATTERN)
        end
      end
    end
  end
end
