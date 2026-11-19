# frozen_string_literal: true

require 'digest'
require 'legion/logging/helper'
require 'legion/extensions/llm/canonical'

module Legion
  module LLM
    # Shared audit projection, independent of inference and transport publishing.
    module AuditProjection
      extend Legion::Logging::Helper

      module_function

      def capture_metadata(message_count:)
        {
          mode: :full, original_message_count: message_count,
          captured_message_count: message_count, omitted_message_count: 0,
          redacted_binary_count: 0, redacted_binary_bytes: 0, omitted_field_count: 0,
          reasons: []
        }
      end

      # Canonical blocks can occur singly, in arrays, or inside tool results,
      # arguments and metadata. Copy containers only; never modify inference
      # objects or copy their binary strings. A fingerprint is not base64 data.
      def project_value(value:, binary_limit:, capture:, fingerprints:, binary_type: nil)
        case value
        when Legion::Extensions::Llm::Canonical::Message,
             Legion::Extensions::Llm::Canonical::ContentBlock,
             Legion::Extensions::Llm::Canonical::ToolCall
          project_value(value: value.to_h, binary_limit: binary_limit, capture: capture, fingerprints: fingerprints)
        when Array
          value.map do |item|
            project_value(value: item, binary_limit: binary_limit, capture: capture, fingerprints: fingerprints)
          end
        when Hash
          project_hash(value: value, binary_limit: binary_limit, capture: capture,
                       fingerprints: fingerprints, binary_type: binary_type)
        else
          value
        end
      end

      def project_hash(value:, binary_limit:, capture:, fingerprints:, binary_type:)
        type = hash_value(value, :type).to_s
        media = binary_type || (%w[image audio video].include?(type) && type)
        projected = value.to_h do |key, item|
          nested_media = media if key.to_s == 'source'
          [key, project_value(value: item, binary_limit: binary_limit, capture: capture,
                              fingerprints: fingerprints, binary_type: nested_media)]
        end
        data = hash_value(value, :data)
        source_type = hash_value(value, :source_type) || (binary_type && hash_value(value, :type))
        return projected unless media && source_type.to_s != 'url' && data.is_a?(String) && data.bytesize > binary_limit

        fingerprint = fingerprints[data] ||= { bytes: data.bytesize, sha256: Digest::SHA256.hexdigest(data) }
        projected.delete(:data)
        projected.delete('data')
        projected.delete(:source_type)
        projected.delete('source_type')
        projected[:binary_fingerprint] = fingerprint.merge(media_type: hash_value(value, :media_type), source_type: source_type).compact
        if capture
          capture[:redacted_binary_count] += 1
          capture[:redacted_binary_bytes] += data.bytesize
          mark_projection(capture: capture, reason: binary_limit.negative? ? :payload_limit : :binary_limit)
        end
        projected
      end

      def mark_projection(capture:, reason:)
        capture[:mode] = :projected
        capture[:reasons] |= [reason]
      end

      def audit_max_binary_data_bytes
        Legion::Settings[:llm][:compliance][:audit_max_binary_data_bytes]
      end

      def hash_value(hash, key)
        return nil unless hash.respond_to?(:key?)

        string_key = key.to_s
        return hash[string_key] if hash.key?(string_key)

        hash[key] if hash.key?(key)
      end
    end
  end
end
