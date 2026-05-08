# frozen_string_literal: true

require_relative 'caller_identity'

module Legion
  module LLM
    module PublisherIdentity
      GENERIC_PUBLISHER_IDENTITIES = %w[
        anonymous process:anonymous service:system system system:system unknown:anonymous
      ].freeze

      module_function

      def current
        process = process_identity_module
        identity = process_identity(process)
        return identity if present_identity?(identity)

        env_identity
      end

      def caller_hash
        identity = current
        {
          requested_by: {
            identity:   identity[:identity],
            type:       identity[:type],
            credential: identity[:credential],
            hostname:   identity[:hostname]
          }.compact
        }
      end

      def requested_by
        caller_hash[:requested_by]
      end

      def generic_requested_by?(value)
        requested = value.is_a?(Hash) ? value : {}
        raw_id = hash_value(requested, :id).to_s
        return true if raw_id == 'system:system'

        identity = CallerIdentity.normalize(caller: { requested_by: requested })
        normalized = identity[:identity].to_s
        GENERIC_PUBLISHER_IDENTITIES.include?(normalized)
      end

      def process_identity_module
        return Legion::Identity::Process if defined?(Legion::Identity::Process)

        begin
          require 'legion/identity/process'
        rescue LoadError
          nil
        end

        defined?(Legion::Identity::Process) ? Legion::Identity::Process : nil
      end

      def process_identity(process)
        return nil unless process

        canonical = process_value(process, :canonical_name)
        return nil unless present?(canonical)

        CallerIdentity.normalize(
          caller: {
            requested_by: {
              identity:   canonical,
              type:       process_value(process, :kind) || :process,
              credential: process_value(process, :source) || :system,
              hostname:   process_value(process, :hostname)
            }.compact
          }
        )
      end

      def env_identity
        raw = ENV.fetch('USER', nil) || ENV.fetch('LOGNAME', nil)
        return CallerIdentity::DEFAULT_IDENTITY.dup unless present?(raw)

        CallerIdentity.normalize(
          caller: {
            requested_by: {
              identity:   raw.to_s,
              type:       :human,
              credential: :system
            }
          }
        )
      end

      def process_value(process, method_name)
        return nil unless process.respond_to?(method_name)

        process.public_send(method_name)
      rescue StandardError
        nil
      end

      def hash_value(hash, key)
        return nil unless hash.respond_to?(:key?)
        return hash[key] if hash.key?(key)

        string_key = key.to_s
        hash[string_key] if hash.key?(string_key)
      end

      def present_identity?(identity)
        identity.is_a?(Hash) && present?(identity[:identity])
      end

      def present?(value)
        !value.nil? && !(value.respond_to?(:empty?) && value.empty?)
      end
    end
  end
end
