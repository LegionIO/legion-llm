# frozen_string_literal: true

require 'faraday'

module Legion
  module LLM
    module Inference
      class Executor
        # Routing-area methods extracted from Executor verbatim (P4b §1.5, refactor-under-green).
        # Operates on Executor instance state; see P4b-decomposition-embed.md §1.1 for the ivar
        # contract this mixin reads/writes.
        module Routing
          def normalize_offering_metadata(value)
            return {} unless value.is_a?(Hash)

            value.each_with_object({}) do |(key, metadata_value), normalized|
              normalized[key.respond_to?(:to_sym) ? key.to_sym : key] = metadata_value
            end
          end

          def local_provider?
            %i[ollama vllm].include?(@resolved_provider&.to_sym)
          end

          def step_tier_assignment
            gaia_hint = @enrichments['gaia:routing_hint']
            classification = @enrichments['classification:scan']
            assignment = Steps::TierAssigner.assign(
              caller:          @request.caller,
              classification:  classification,
              priority:        @request.priority,
              gaia_hint:       gaia_hint,
              existing_tier:   @request.extra[:tier],
              existing_intent: @request.extra[:intent]
            )
            return unless assignment

            @proactive_tier_assignment = assignment
            @applied_signals[:envelope_keys] << "tier_assigned:#{assignment[:source]}" if @applied_signals.is_a?(Hash)

            @audit[:'routing:tier_assignment'] = {
              outcome:     :success,
              detail:      "proactive tier=#{assignment[:tier]} source=#{assignment[:source]}",
              data:        assignment,
              duration_ms: 0,
              timestamp:   Time.now
            }
            @timeline.record(
              category: :audit, key: 'routing:tier_assignment',
              direction: :internal,
              detail: "tier=#{assignment[:tier]} assigned by #{assignment[:source]}",
              from: 'tier_assigner', to: 'pipeline'
            )
          rescue StandardError => e
            @warnings << "tier assignment error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.step_tier_assignment')
          end

          # SSOT v3 single-engine: step_routing derives the immutable
          # RequestRequirements ONCE. It performs NO selection — no request_lane,
          # no infer_provider, no default model/provider, no tier fabrication.
          # The exact provider+instance+model is chosen only by Router.next_lane
          # inside the RoutingSession loop at dispatch time, and @resolved_* are
          # populated from that Selection. Failure raises (never nil-fail-open to
          # a legacy path — there is no legacy path).
          def step_routing
            @timestamps[:routing_start] = Time.now
            build_ssot_v3_routing_requirements
            @timeline.record(
              category: :audit, key: 'routing:requirements',
              direction: :internal,
              detail: "operation=#{@routing_requirements.operation} caps=#{@routing_requirements.required_capabilities.inspect}",
              from: 'router', to: 'pipeline'
            )
          end

          # SSOT v3 §9/§14 — build the immutable RequestRequirements once per
          # request. Required output size participates in context eligibility
          # (directive: never exclude it). No inventory-generation gate: an empty
          # Registry yields a typed too_early/service_unavailable Rejection from
          # next_lane, never a fabricated lane or a legacy fallback.
          def build_ssot_v3_routing_requirements
            operation = @request.stream == true ? :stream_chat : :chat
            required_caps = Legion::LLM::Router::RequiredCapabilities.call(
              request: @request, operation: operation
            )
            framing = @request.routing_settings_snapshot.input_framing_overhead_tokens
            input_bound = Legion::LLM::Router::InputBound.call(
              operation:               operation,
              messages:                @request.messages,
              system:                  @request.system,
              tools:                   @request.tools,
              tool_choice:             @request.tool_choice,
              thinking:                @request.thinking,
              response_format:         @request.response_format,
              framing_overhead_tokens: framing
            )
            @routing_requirements = Legion::LLM::Router::RequestRequirements.build(
              request:                @request,
              operation:              operation,
              required_capabilities:  required_caps,
              estimated_input_bound:  input_bound,
              required_output_tokens: required_output_tokens_for_request
            )
            log.debug "[llm][executor] action=ssot_v3_requirements_built operation=#{operation} " \
                      "output_tokens=#{@routing_requirements.required_output_tokens}"
          end

          # Requested max output tokens — sourced from the canonical request token
          # budget so context eligibility accounts for output size. Zero when the
          # caller set no budget.
          def required_output_tokens_for_request
            tokens = @request.tokens
            max = tokens.is_a?(Hash) ? (tokens[:max] || tokens[:max_tokens]) : nil
            [max.to_i, 0].max
          end

          def step_request_normalization
            @exchange_id = Tracing.exchange_id
            Thread.current[:legion_log_exchange_id] = @exchange_id
          end

          def use_native_dispatch?(provider)
            return false unless defined?(Call::Dispatch)
            return false unless provider

            layer_settings = Legion::Settings.dig(:llm, :provider_layer) || {}
            mode = (layer_settings[:mode] || 'auto').to_s

            %w[native auto].include?(mode)
          end

          def merge_response_offering_metadata(metadata)
            return unless metadata.is_a?(Hash)

            offering = normalize_offering_metadata(metadata[:offering] || metadata['offering'] || metadata)
            return if offering.empty?

            @resolved_offering_metadata = @resolved_offering_metadata.merge(offering)
            @resolved_offering_id = @resolved_offering_metadata[:offering_id] if @resolved_offering_id.nil?
          end
        end
      end
    end
  end
end
