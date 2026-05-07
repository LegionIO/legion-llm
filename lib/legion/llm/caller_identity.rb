# frozen_string_literal: true

module Legion
  module LLM
    module CallerIdentity
      GENERIC_IDENTITIES = %w[anonymous process service system user].freeze
      DEFAULT_IDENTITY = { identity: 'unknown:anonymous', type: 'unknown' }.freeze

      module_function

      def normalize(caller: nil, identity: nil)
        return normalize_string(caller) if caller.is_a?(String)

        caller_hash = caller.is_a?(Hash) ? caller : {}
        requested_by = hash_value(caller_hash, :requested_by)
        requested_by = caller_hash unless requested_by.is_a?(Hash)

        top_identity = normalize_identity_option(identity)
        extension = hash_value(caller_hash, :extension)
        type = first_present(
          hash_value(requested_by, :type),
          hash_value(top_identity, :type),
          extension && 'extension'
        )

        raw_identity = first_present(
          hash_value(requested_by, :id),
          hash_value(requested_by, :canonical_name),
          hash_value(top_identity, :id),
          hash_value(top_identity, :canonical_name),
          hash_value(top_identity, :identity),
          hash_value(top_identity, :username),
          hash_value(requested_by, :identity),
          hash_value(requested_by, :username),
          extension && "extension:#{extension}"
        )

        result = {
          identity:   normalize_identity_value(raw_identity, type),
          type:       type,
          credential: first_present(hash_value(requested_by, :credential), hash_value(top_identity, :credential)),
          hostname:   hash_value(requested_by, :hostname)
        }.compact
        result.empty? ? DEFAULT_IDENTITY.dup : result
      end

      def normalize_string(value)
        return DEFAULT_IDENTITY.dup unless present?(value)

        type = value.to_s.include?(':') ? value.to_s.split(':', 2).first : nil
        { identity: value.to_s, type: type }.compact
      end

      def normalize_identity_option(value)
        case value
        when Hash
          value
        when String
          { identity: value }
        else
          {}
        end
      end

      def normalize_identity_value(value, type)
        return nil unless present?(value)

        text = value.to_s
        return text if text.include?(':') || text.include?('@')
        return "#{type}:#{text}" if type && GENERIC_IDENTITIES.include?(text)

        text
      end

      def first_present(*values)
        values.find { |value| present?(value) }
      end

      def hash_value(hash, key)
        return nil unless hash.respond_to?(:key?)
        return hash[key] if hash.key?(key)

        string_key = key.to_s
        hash[string_key] if hash.key?(string_key)
      end

      def present?(value)
        !value.nil? && !(value.respond_to?(:empty?) && value.empty?)
      end
    end
  end
end
