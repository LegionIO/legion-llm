# frozen_string_literal: true

require 'legion/llm/errors'

module Legion
  module LLM
    module Routing
      # Trusted routing constraints from canonical X-Legion-* headers (SSOT v3
      # §7.3) or from explicit internal arguments. These are HARD constraints,
      # not body hints — X-Legion-Model is the deliberate escape hatch and is
      # never subject to the D19 body whitelist/blacklist. Malformed trusted
      # hints raise Errors::InvalidHeader (HTTP 400).
      module HeaderConstraints
        extend Legion::Logging::Helper

        HEADER_KEYS = {
          provider:         'X-Legion-Provider',
          instance_id:      'X-Legion-Instance',
          model:            'X-Legion-Model',
          tier:             'X-Legion-Tier',
          maximum_attempts: 'X-Legion-Max-Attempts'
        }.freeze

        # Immutable trusted-constraint value.
        class Value
          attr_reader :provider, :instance_id, :model, :tier, :maximum_attempts

          def initialize(provider:, instance_id:, model:, tier:, maximum_attempts:)
            @provider = provider
            @instance_id = instance_id
            @model = model
            @tier = tier
            @maximum_attempts = maximum_attempts
            freeze
          end
        end

        def self.call(headers:, settings_snapshot:)
          raw = HEADER_KEYS.transform_values { |name| fetch_header(headers, name) }
          from_internal(
            provider: raw[:provider], instance_id: raw[:instance_id], model: raw[:model],
            tier: raw[:tier], maximum_attempts: raw[:maximum_attempts], settings_snapshot: settings_snapshot
          )
        end

        def self.from_internal(settings_snapshot:, provider: nil, instance_id: nil, model: nil,
                               tier: nil, maximum_attempts: nil)
          Value.new(
            provider:         normalize_provider(normalize_utf8!(provider, HEADER_KEYS[:provider])),
            instance_id:      blank_to_nil(normalize_utf8!(instance_id, HEADER_KEYS[:instance_id])),
            model:            blank_to_nil(normalize_utf8!(model, HEADER_KEYS[:model])),
            tier:             normalize_tier(normalize_utf8!(tier, HEADER_KEYS[:tier])),
            maximum_attempts: normalize_max_attempts(normalize_utf8!(maximum_attempts, HEADER_KEYS[:maximum_attempts]),
                                                     settings_snapshot)
          )
        end

        # Read a canonical header name from either a normalized headers Hash
        # ('X-Legion-Provider') or a Rack env Hash ('HTTP_X_LEGION_PROVIDER').
        def self.fetch_header(headers, name)
          return nil if headers.nil?

          rack = "HTTP_#{name.upcase.tr('-', '_')}"
          value = headers[name] || headers[name.downcase] || headers[rack]
          normalize_utf8!(value&.to_s, name)
        end
        private_class_method :fetch_header

        # Trust boundary: Puma 8 serves HTTP header values as ASCII-8BIT
        # (BINARY) strings, and the frozen lex-llm inventory records accept
        # only valid UTF-8/US-ASCII — a BINARY pin would crash Rejection
        # validation (HTTP 500). ASCII-8BIT ASCII-only bytes re-encode to
        # UTF-8 losslessly; genuinely invalid UTF-8 is a malformed trusted
        # hint (Errors::InvalidHeader, HTTP 400).
        def self.normalize_utf8!(value, header)
          return value unless value.is_a?(String)
          return value if value.encoding == Encoding::UTF_8 && value.valid_encoding?

          normalized = value.dup.force_encoding(Encoding::UTF_8)
          return normalized if normalized.valid_encoding?

          raise Legion::LLM::Errors::InvalidHeader.new(
            header: header, got: value, valid: [],
            message: "#{header} value must be valid UTF-8"
          )
        end
        private_class_method :normalize_utf8!

        def self.blank_to_nil(value)
          return nil if value.nil?

          trimmed = value.to_s.strip
          return nil if trimmed.empty?

          reject_multi!(trimmed)
          trimmed
        end
        private_class_method :blank_to_nil

        def self.reject_multi!(value)
          return unless value.include?(',')

          raise Legion::LLM::Errors::InvalidHeader.new(
            header: 'X-Legion-*', got: value, valid: [],
            message: 'comma-separated/duplicate trusted routing hints are not permitted'
          )
        end
        private_class_method :reject_multi!

        def self.normalize_provider(value)
          v = blank_to_nil(value)
          v&.downcase
        end
        private_class_method :normalize_provider

        def self.normalize_tier(value)
          v = blank_to_nil(value)
          return nil if v.nil?

          sym = v.downcase.to_sym
          unless Legion::Extensions::Llm::Taxonomies::TIERS.include?(sym)
            raise Legion::LLM::Errors::InvalidHeader.new(
              header: HEADER_KEYS[:tier], got: value, valid: Legion::Extensions::Llm::Taxonomies::TIERS
            )
          end
          sym
        end
        private_class_method :normalize_tier

        def self.normalize_max_attempts(value, settings_snapshot)
          v = blank_to_nil(value)
          return nil if v.nil?

          raise Legion::LLM::Errors::InvalidHeader.new(header: HEADER_KEYS[:maximum_attempts], got: value, valid: []) unless v.match?(/\A\d+\z/)

          n = Integer(v, 10)
          ceiling = settings_snapshot.maximum_attempts
          unless n.positive? && n <= ceiling
            raise Legion::LLM::Errors::InvalidHeader.new(
              header: HEADER_KEYS[:maximum_attempts], got: value, valid: (1..ceiling).to_a,
              message: "max attempts must be an integer in 1..#{ceiling}"
            )
          end
          n
        end
        private_class_method :normalize_max_attempts
      end
    end
  end
end
