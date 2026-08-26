# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      class Executor
        # Single ingress site for routing_payload construction (C2).
        # Parses x-legion-* headers, validates against Taxonomies, gates body hints,
        # and assembles the dumb hash threaded through Router.request_lane.
        # C2 replaces build_routing_payload_from_resolved from C1.
        module PayloadBuilder
          extend Legion::Logging::Helper

          module_function

          # Build the routing_payload from headers, body, and classification.
          # Called once per request at the executor ingress.
          # H-H / sonnet G4: body model always honored; body tier/provider/instance
          # gated by allow_body_routing_hints setting.
          def build(request:, headers:, **)
            body = request.respond_to?(:body) ? (request.body || {}) : {}
            # When called from the executor context, body may be empty; fall back to
            # routing[:model] which was parsed from the HTTP body by the client translator.
            body_model = body[:model] || body['model'] ||
                         (request.respond_to?(:routing) ? (request.routing[:model] || request.routing['model']) : nil)

            tiers     = parse_and_validate_header(headers: headers, name: 'x-legion-tiers',
                                                  taxonomy: Legion::Extensions::Llm::Taxonomies::TIERS)
            providers = parse_header_array(headers: headers, name: 'x-legion-providers')
            instances = parse_header_array(headers: headers, name: 'x-legion-instances')
            models    = body_model ? [body_model.to_s] : parse_header_array(headers: headers, name: 'x-legion-models')

            if body_hints_enabled?
              tiers     |= body_symbol_array(body: body, key: :tier)
              providers |= body_symbol_array(body: body, key: :provider)
              instances |= body_symbol_array(body: body, key: :instance)
            end

            capabilities = Legion::Extensions::Llm::Capabilities.normalize(
              derive_capabilities(request: request)
            )

            {
              type:              :inference,
              tiers:             tiers,
              providers:         providers,
              instances:         instances,
              models:            models,
              capabilities:      capabilities,
              thinking:          derive_thinking(request: request),
              privacy:           derive_privacy(request: request),
              estimated_context: nil,
              tried_lanes:       [],
              max_attempts:      header_int(headers: headers, name: 'x-legion-max-attempts') ||
                Legion::Settings[:llm][:routing][:max_attempts],
              rng:               nil
            }
          end

          # G31 / opus M7: validate header values against taxonomy. Raises Errors::InvalidHeader
          # (mapped to 400) on unknown values. Returns symbol array of valid values.
          def parse_and_validate_header(headers:, name:, taxonomy:, **)
            values = parse_header_array(headers: headers, name: name)
            return values if values.empty?

            bad = values - taxonomy
            return values if bad.empty?

            raise Legion::LLM::Errors::InvalidHeader.new(
              header: name, got: bad, valid: taxonomy
            )
          end

          def parse_header_array(headers:, name:, **)
            raw = headers[name] || headers[name.upcase] || headers[name.tr('-', '_').upcase]
            return [] if raw.nil? || raw.to_s.empty?

            raw.to_s.split(',').map(&:strip).reject(&:empty?).map(&:to_sym)
          end

          def header_int(headers:, name:, **)
            raw = headers[name] || headers[name.upcase] || headers[name.tr('-', '_').upcase]
            return nil if raw.nil? || raw.to_s.empty?

            Integer(raw.to_s, 10)
          rescue ArgumentError
            nil
          end

          def body_hints_enabled?
            Legion::Settings[:llm][:routing][:allow_body_routing_hints] == true
          end

          def body_symbol_array(body:, key:, **)
            Array(body[key] || body[key.to_s]).map(&:to_sym).reject { |s| s.to_s.empty? }
          end

          def derive_capabilities(request:, **)
            caps = []
            tools = request.respond_to?(:tools) ? request.tools : nil
            caps << :tools if tools.is_a?(Array) && tools.any?
            caps
          end

          def derive_thinking(request:, **)
            thinking = request.respond_to?(:thinking) ? request.thinking : nil
            return :any if thinking.nil?
            return thinking.any? ? :require : :any if thinking.is_a?(Hash)

            # N2: shared execution carries canonical thinking — a
            # Thinking::Config (or a canonical {effort:, budget:} Hash from
            # the Prompt API), never a client-dialect shape. An explicit
            # effort or budget is a thinking requirement.
            effort = thinking.respond_to?(:effort) ? thinking.effort : nil
            budget = thinking.respond_to?(:budget) ? thinking.budget : nil
            effort || budget ? :require : :any
          end

          def derive_privacy(request:, **)
            classification = request.respond_to?(:classification) ? request.classification : nil
            return :normal unless classification.is_a?(Hash)

            classification[:privacy]&.to_sym == :strict ? :strict : :normal
          rescue StandardError => e
            # No-fail-open: a classification fault must never silently downgrade
            # the request's privacy. Fail closed to :strict so routing is
            # constrained, not opened.
            handle_exception(e, level: :error, operation: 'llm.inference.derive_privacy')
            :strict
          end
        end
      end
    end
  end
end
