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

          # SSOT v4 single-engine: step_routing builds the per-request Router
          # ONCE. It performs NO selection — no request_lane, no infer_provider,
          # no default model/provider, no tier fabrication. The exact
          # provider+instance+model is chosen only by Router#next_lane inside the
          # attempt loop at dispatch time, and @resolved_* are populated from
          # that Selection. Failure raises (never nil-fail-open to a legacy path
          # — there is no legacy path).
          def step_routing
            @timestamps[:routing_start] = Time.now
            build_ssot_router
            @timeline.record(
              category: :audit, key: 'routing:requirements',
              direction: :internal,
              detail: "operation=#{@router.operation} caps=#{@router.required_capabilities.inspect}",
              from: 'router', to: 'pipeline'
            )
          end

          # SSOT v4 — build the per-request Router once. The Router derives
          # required capabilities, input bound, context budget, and output tokens
          # internally from the request and operation. No inventory-generation
          # gate: an empty Registry yields a typed too_early/service_unavailable
          # Rejection from next_lane, never a fabricated lane or a legacy fallback.
          def build_ssot_router
            operation = @request.stream == true ? :stream_chat : :chat
            body_model = @request.metadata[:client_model]
            @router = Legion::LLM::Router.new(
              request:    @request,
              operation:  operation,
              body_model: body_model
            )
            log.debug "[llm][executor] action=ssot_router_built operation=#{operation} " \
                      "output_tokens=#{@router.required_output_tokens}"
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

          # M10: an honest dispatch gate. In SSOT mode the attempt context
          # is set and dispatch executes the Selection's exact inventory
          # callable — no legacy extension-registry entry is in the path
          # (stale/disposed callables surface as typed inventory errors,
          # never a registry miss). On the legacy Call::Dispatch path the
          # extension is resolved by name, so the gate checks the registry
          # exactly as Dispatch.available? does.
          def use_native_dispatch?(provider)
            return false unless provider
            return true if @current_attempt_context
            return false unless defined?(Call::Dispatch)

            layer_settings = Legion::Settings.dig(:llm, :provider_layer) || {}
            mode = (layer_settings[:mode] || 'auto').to_s

            %w[native auto].include?(mode) && Call::Dispatch.available?(provider)
          end

          def merge_response_offering_metadata(metadata)
            return unless metadata.is_a?(Hash)

            offering = normalize_offering_metadata(metadata[:offering] || metadata['offering'] || metadata)
            return if offering.empty?

            # M6: response metadata is descriptive data (limits, context
            # window) — it must never write routing identity. Offering
            # identity is Selection-owned; a provider-asserted offering_id
            # stays inert data in the metadata, not @resolved_offering_id.
            @resolved_offering_metadata = @resolved_offering_metadata.merge(offering)
          end
        end
      end
    end
  end
end
