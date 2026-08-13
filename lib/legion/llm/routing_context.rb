# frozen_string_literal: true

require 'securerandom'
require 'legion/llm/errors'

module Legion
  module LLM
    # Trusted per-logical-request routing context (SSOT v3 D15 / §7.1).
    #
    # Carries one opaque 128-bit server-generated routing seed, immutable across
    # the request's initial attempt, retries, streaming failover, and embedding
    # batch restart. No API header, body field, query parameter, translated
    # request field, provider response, or GAIA payload can set the seed — it is
    # created only by `build` via SecureRandom, or injected by `for_test` for
    # deterministic specs. A request that bypassed the builder or carries a
    # malformed seed is an internal programming/protocol failure
    # (Errors::InvalidRoutingContext, HTTP 500), never a client error.
    class RoutingContext
      include Legion::Logging::Helper

      SEED_FORMAT = /\A[0-9a-f]{32}\z/

      class << self
        # Production constructor: one fresh server-generated seed.
        def build
          new(routing_seed: SecureRandom.hex(16))
        end

        # Deterministic test constructor. Raises outside RSpec so no production
        # path can inject a fixed seed.
        def for_test(routing_seed:)
          unless defined?(::RSpec)
            raise Legion::LLM::Errors::InvalidRoutingContext,
                  'RoutingContext.for_test is only available under RSpec'
          end
          new(routing_seed: routing_seed)
        end

        private :new
      end

      attr_reader :routing_seed

      def initialize(routing_seed:)
        seed = routing_seed.to_s.dup
        unless seed.match?(SEED_FORMAT)
          raise Legion::LLM::Errors::InvalidRoutingContext,
                'routing_seed must be exactly 32 lowercase hexadecimal characters'
        end
        @routing_seed = seed.freeze
        freeze
      end
    end
  end
end
