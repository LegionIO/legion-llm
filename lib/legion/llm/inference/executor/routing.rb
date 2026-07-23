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

          def inferred_provider_tier(provider)
            return nil unless provider

            meta = Call::Registry.metadata_for(provider, @resolved_instance || :default)
            return meta[:tier].to_sym if meta.is_a?(Hash) && meta[:tier]
            return Router.provider_tier(provider) if defined?(Router) && Router.respond_to?(:provider_tier)

            Router::PROVIDER_TIER.fetch(provider.to_sym, nil) if defined?(Router::PROVIDER_TIER)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.inferred_provider_tier',
                                provider: provider)
            nil
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

          def step_routing
            log.debug "[llm][executor] action=step_routing.enter requested_provider=#{@request.routing[:provider]} requested_model=#{@request.routing[:model]}"
            @timestamps[:routing_start] = Time.now
            state = resolve_routing_state(apply_proactive_tier_assignment(resolve_model_to_local_provider(routing_request_state)))
            auto_route = state[:auto_route] == true

            inferred = state[:model] && Router.infer_provider_for_model(state[:model])
            inferred = nil unless state[:provider] || (inferred && Call::Registry.registered?(inferred))
            @resolved_provider = state[:provider] ||
                                 inferred ||
                                 (Legion::Settings[:llm][:default_provider] unless auto_route)
            @resolved_instance = resolve_provider_instance(state[:instance], @resolved_provider)

            # If the resolved provider differs from the model's natural provider, swap to the
            # provider's default model — sending "claude-sonnet-4-6" to vllm would fail.
            resolved_model = state[:model]
            if resolved_model && @resolved_provider
              model_natural = Router.infer_provider_for_model(resolved_model)
              if model_natural && !model_natural.to_s.eql?(@resolved_provider.to_s)
                log.debug "[llm][executor] action=model_provider_mismatch model=#{resolved_model} " \
                          "natural_provider=#{model_natural} resolved_provider=#{@resolved_provider} swapping"
                resolved_model = nil
              end
            end
            @resolved_model = resolved_model || fallback_model_for_resolved_provider(auto_route)
            raise ProviderError, 'Auto routing could not resolve an available LLM provider/model' if auto_route && (@resolved_provider.nil? || @resolved_model.nil?)

            @resolved_tier = state[:tier]&.to_sym || inferred_provider_tier(@resolved_provider)
            @resolved_offering_id = state[:offering_id]
            @resolved_offering_metadata = state[:offering_metadata]
            record_forced_tier_selection unless @audit[:'routing:provider_selection']

            log.info '[llm][inference] resolved ' \
                     "provider=#{@resolved_provider} instance=#{@resolved_instance || 'default'} " \
                     "model=#{@resolved_model} offering_id=#{@resolved_offering_id}"
            @timeline.record(
              category: :audit, key: 'routing:provider_selection',
              direction: :internal, detail: "routed to #{@resolved_provider}:#{@resolved_model}",
              from: 'router', to: 'pipeline'
            )
          end

          # When routing resolved a provider but no model, source the model from that
          # provider's own catalog (Inventory SSOT) — never the global default_model,
          # which may belong to a different provider. This prevents pairing e.g.
          # anthropic with a vllm-family global default. The global default applies
          # only when no provider resolved, or the resolved provider IS the configured
          # default_provider (so the global default legitimately belongs to it).
          def fallback_model_for_resolved_provider(auto_route)
            return nil if auto_route

            if @resolved_provider && Router.respond_to?(:inventory_default_model)
              provider_model = Router.inventory_default_model(@resolved_provider, @resolved_instance)
              return provider_model if provider_model
            end

            global = Legion::Settings[:llm][:default_model]
            return nil if global.nil? || global.to_s.empty?

            default_provider = Legion::Settings[:llm][:default_provider]&.to_sym
            return global if @resolved_provider.nil? || @resolved_provider.to_sym == default_provider

            nil
          end

          def resolve_provider_instance(requested_instance, provider)
            return provider_scoped_instance(requested_instance, provider, preserve_unknown: true) if requested_instance

            provider_scoped_instance(Legion::Settings[:llm][:default_instance], provider, preserve_unknown: false)
          end

          def provider_scoped_instance(instance, provider, preserve_unknown:)
            return nil if instance.nil? || instance.to_s.empty? || provider.nil? || provider.to_s.empty?

            provider_sym = provider.to_sym
            instance_sym = instance.to_sym
            return instance_sym if Call::Registry.registered?(provider_sym, instance: instance_sym)

            if Call::Registry.registered?(provider_sym)
              # Provider is registered but the specific instance is not.
              # Only return nil if there's at least one instance registered for this provider.
              instances = Call::Registry.instances_for(provider_sym)
              return nil if instances.is_a?(Array) && instances.any?
            end

            preserve_unknown ? instance_sym : nil
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.provider_scoped_instance')
            preserve_unknown ? instance : nil
          end

          def routing_request_state
            routing_explicit = @request.extra[:routing_explicit]
            request_intent = @request.extra[:intent]
            instance = @request.routing[:instance] || @request.routing[:instance_id] || @request.routing[:provider_instance]
            tier = @request.extra[:tier]
            {
              provider:          @request.routing[:provider],
              instance:          instance,
              model:             routing_model_preference,
              offering_id:       @request.routing[:offering_id] || @request.routing[:id],
              offering_metadata: normalize_offering_metadata(@request.routing[:offering_metadata] ||
                                                             @request.routing[:offering]),
              intent:            routing_intent_for_request(request_intent),
              intent_explicit:   routing_intent_present?(request_intent),
              tier:              tier,
              auto_route:        @request.extra[:auto_route],
              provider_explicit: routing_field_explicit?(routing_explicit, :provider, @request.routing[:provider]),
              instance_explicit: routing_field_explicit?(routing_explicit, :instance, instance),
              tier_explicit:     routing_field_explicit?(routing_explicit, :tier, tier),
              estimated_tokens:  estimate_request_tokens
            }
          end

          def routing_model_preference
            explicit_model = @request.routing[:model]
            return explicit_model unless explicit_model.nil? || explicit_model.to_s.empty?

            client_model = @request.metadata&.dig(:client_model)&.to_s
            return nil if client_model.nil? || client_model.empty?
            return nil if Legion::LLM::Inference::Request.auto_routing_model?(client_model)
            return nil unless body_routing_hints_enabled?

            client_model
          end

          def body_routing_hints_enabled?
            Legion::Settings.dig(:llm, :routing, :allow_body_routing_hints) == true
          end

          # One oracle: routing must estimate the SAME payload the dispatch guard
          # (RouteAttempts#final_dispatch_token_estimate) measures, or a too-small
          # lane passes the router's context-window filter then overflows at
          # dispatch. Use ContextAccounting (walks canonical structs / content
          # blocks) for messages, estimate the INJECTED system (baseline + RAG +
          # skills + prior-history text), and count client tools. Messages are the
          # lane-independent-reduced set — what actually goes on the wire.
          def estimate_request_tokens
            # Mirror the dispatch shape EXACTLY: native_dispatch_messages sends
            # @request.messages (lane-independent-reduced); the conversation
            # history lives in the injected SYSTEM (via EnrichmentInjector), not
            # in the messages array — counting it in both would double-count.
            reduced = reduce_messages_for_dispatch(Array(@request.messages))

            estimated  = ContextAccounting.estimate_message_tokens(reduced)
            estimated += ContextAccounting.estimate_text_tokens(routing_estimate_injected_system)
            estimated += ContextAccounting.estimate_json_tokens(routing_estimate_tool_defs)
            estimated += ContextAccounting.estimate_json_tokens(@request.tool_choice) if @request.tool_choice
            estimated += ContextAccounting.estimate_json_tokens(@request.thinking) if @request.thinking.is_a?(Hash) && @request.thinking.any?
            estimated
          end

          # The system prompt as it will be dispatched — baseline + GAIA + prior
          # history + RAG + skills injected. EnrichmentInjector.inject is pure, so
          # calling it here and again at dispatch has no side effects.
          def routing_estimate_injected_system
            EnrichmentInjector.inject(system: @request.system, enrichments: @enrichments || {})
          end

          # The tool catalog dispatch will send (special + client + registry), NOT
          # just @request.tools — the dispatch guard counts native_dispatch_tools,
          # so routing must too or a heavy-tool request under-counts and picks a
          # too-small lane. Built read-only here (never memoized) because
          # native_tool_definitions caches and applies the local-provider cap
          # against @resolved_provider, which is not set at routing time; an
          # uncapped over-estimate is the safe direction for a "will it fit" filter.
          def routing_estimate_tool_defs
            defs = Tools::Special.pinned_definitions.map(&:to_h)
            Array(@request.tools).each { |t| defs << (t.respond_to?(:to_h) ? t.to_h : t) }
            Legion::Settings::Extensions.filter_tools(deferred: false).each { |e| defs << e } if registry_tool_injection_requested?
            defs
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.routing_estimate_tool_defs')
            Array(@request.tools).map { |t| t.respond_to?(:to_h) ? t.to_h : t }
          end

          def chain_required_capabilities
            caps = []
            caps << :streaming if @request.stream == true
            caps << :tools     if native_tools_requested_for_routing?
            caps
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.chain_required_capabilities')
            []
          end

          def routing_intent_present?(intent)
            intent.is_a?(Hash) && intent.any?
          end

          def routing_intent_for_request(intent)
            normalized = if intent.is_a?(Hash)
                           intent.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                         else
                           {}
                         end
            required = normalize_required_capabilities(
              normalized.delete(:required_capabilities) || normalized.delete(:requires)
            )

            normalized[:operation] = :stream if @request.stream == true
            normalized[:operation] ||= :chat
            normalized[:effort] ||= :moderate

            required << :streaming if @request.stream == true
            required << :tools if native_tools_requested_for_routing?
            required << :vision if request_has_vision_content?
            required << :thinking if request_requires_thinking?
            normalized[:required_capabilities] = required.uniq if required.any?
            normalized
          end

          def request_requires_thinking?
            thinking = @request.thinking
            return true if thinking.is_a?(Hash) && thinking.any?
            return true if thinking.respond_to?(:to_h) && thinking.to_h.any?

            extra = @request.extra || {}
            return false unless extra.is_a?(Hash)

            normalized_extra = extra.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
            !!(normalized_extra[:thinking] || normalized_extra[:reasoning] || normalized_extra[:max_thinking_tokens])
          end

          def request_has_vision_content?
            return true if @request.modality == :vision

            @request.messages.any? do |msg|
              content = msg[:content] || msg['content']
              next false unless content.is_a?(Array)

              content.any? do |block|
                next false unless block.is_a?(Hash)

                type = (block[:type] || block['type']).to_s
                type == 'image' || type == 'image_url' ||
                  (block[:source] && (block.dig(:source, :type) || block.dig(:source, 'type')).to_s == 'base64')
              end
            end
          end

          def native_tools_requested_for_routing?
            Array(@request.tools).any? ||
              requested_deferred_tool_names.any?
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.routing_tools_required')
            false
          end

          def normalize_required_capabilities(capabilities)
            aliases = {
              function_calling: :tools,
              functions:        :tools,
              tool:             :tools,
              tool_use:         :tools,
              stream:           :streaming,
              stream_chat:      :streaming
            }
            Array(capabilities).compact.each_with_object([]) do |capability, normalized|
              next unless capability.respond_to?(:to_s)

              capability_sym = capability.to_s.downcase.strip.to_sym
              next if capability_sym.to_s.empty?

              normalized << capability_sym
              alias_sym = aliases[capability_sym]
              normalized << alias_sym if alias_sym
            end.uniq
          end

          def apply_proactive_tier_assignment(state)
            # Forced assignments carry security/privacy constraints and override
            # caller-supplied tier/intent. Advisory assignments only fill blanks.
            if @proactive_tier_assignment&.dig(:forced)
              state[:tier] = @proactive_tier_assignment[:tier]
              state[:tier_explicit] = true
              state[:intent] = merge_routing_intent(state[:intent], @proactive_tier_assignment[:intent])
              log.info "[llm][routing] action=forced_tier source=#{@proactive_tier_assignment[:source]} tier=#{state[:tier]}"
            elsif @proactive_tier_assignment && !state[:tier] && !state[:intent] && !state[:instance] &&
                  !state[:provider] && !state[:model]
              state[:tier] = @proactive_tier_assignment[:tier]
              state[:tier_explicit] = true
              state[:intent] = @proactive_tier_assignment[:intent]
            end
            state
          end

          # If the caller named a model but gave no explicit provider/tier/instance,
          # search discovered providers for that model with a healthy circuit.
          # On a hit: pin provider + instance so normal routing runs against the local copy.
          # On a miss: clear the model name and set auto_route so the pipeline picks the best
          # available provider rather than blindly forwarding a frontier model name.
          #
          # Pin a model to a local/direct provider when the Inventory live store has a
          # matching lane from a locally-registered instance (vLLM, Ollama, MLX).
          # Only local/direct/fleet tiers are eligible — cloud/frontier tiers merely
          # advertise models in their static catalog; routing through them here would
          # pin frontier model names to providers that do not hold a local copy.
          def resolve_model_to_local_provider(state)
            return state if state[:provider_explicit] || state[:tier_explicit] || state[:instance_explicit]
            return state if state[:provider] || state[:tier] || state[:instance]
            return state unless state[:model] && defined?(Legion::LLM::Inventory) && defined?(Router)

            model = state[:model].to_s
            local_tiers = %i[direct local fleet]

            candidates = Legion::LLM::Inventory.lanes_for(model: model, type: :inference).select do |l|
              local_tiers.include?(l[:tier].to_sym) &&
                Call::Registry.registered?(l[:provider_family], instance: l[:instance_id])
            end

            return state if candidates.empty?

            healthy = candidates.find do |l|
              l[:health][:circuit_state] != :open
            end

            if healthy
              log.info "[llm][executor] action=model_discovery_pin model=#{model} " \
                       "provider=#{healthy[:provider_family]} instance=#{healthy[:instance_id]}"
              state[:provider] = healthy[:provider_family]
              state[:instance] = healthy[:instance_id]
            else
              log.info "[llm][executor] action=model_discovery_miss model=#{model} falling_back=auto_route"
              state[:model] = nil
              state[:auto_route] = true
            end

            state
          end

          def resolve_routing_state(state)
            return state unless defined?(Router)
            return state unless Legion::LLM::Inventory.lanes.any?

            resolution = routing_resolution_for(state)
            return state unless resolution

            apply_routing_resolution(state, resolution)
          end

          def routing_resolution_for(state)
            tiers      = state[:tier]     ? [state[:tier].to_sym]     : []
            providers  = state[:provider] ? [state[:provider].to_sym] : []
            instances  = state[:instance] ? [state[:instance].to_sym] : []
            models     = state[:model]    ? [state[:model].to_s]      : []

            lane = Legion::LLM::Router.request_lane(
              type:              :inference,
              tiers:             tiers,
              providers:         providers,
              instances:         instances,
              models:            models,
              capabilities:      chain_required_capabilities,
              estimated_context: state[:estimated_tokens],
              tried_lanes:       Array(state[:tried_lanes])
            )

            return nil if lane.nil?

            Legion::LLM::Router::Resolution.new(
              tier:     lane[:tier],
              provider: lane[:provider_family],
              model:    lane[:model],
              instance: lane[:instance_id],
              rule:     'request_lane'
            )
          end

          def apply_routing_resolution(state, resolution)
            provider_changed = resolution.provider && resolution.provider != state[:provider]
            state[:provider] = resolution.provider
            state[:instance] = if resolution.instance
                                 resolution.instance
                               elsif provider_changed
                                 nil
                               else
                                 state[:instance]
                               end
            state[:model] = resolution.model
            state[:tier] = resolution.tier
            state[:offering_id] = resolution.offering_id || state[:offering_id]
            state[:offering_metadata] = resolution.offering_metadata unless resolution.offering_metadata.empty?
            @audit[:'routing:provider_selection'] = {
              outcome: :success,
              detail: "selected #{state[:provider]}:#{state[:model]} via #{resolution.rule}",
              data: { strategy: resolution.rule, tier: resolution.tier, instance: state[:instance],
                      offering_id: state[:offering_id], offering_metadata: state[:offering_metadata] }.compact,
              duration_ms: 0, timestamp: Time.now
            }
            state
          end

          def routing_field_explicit?(flags, key, value)
            return false if value.nil? || value.to_s.empty?
            return true unless flags.is_a?(Hash)

            flags.fetch(key, flags.fetch(key.to_s, true)) == true
          end

          def merge_routing_intent(existing, assignment)
            existing_hash = existing.is_a?(Hash) ? existing : {}
            assignment_hash = assignment.is_a?(Hash) ? assignment : {}
            existing_hash.merge(assignment_hash)
          end

          def record_forced_tier_selection
            return unless @proactive_tier_assignment&.dig(:forced)

            @audit[:'routing:provider_selection'] = {
              outcome:     :success,
              detail:      "forced tier #{@resolved_tier} by #{@proactive_tier_assignment[:source]}",
              data:        { tier: @resolved_tier, strategy: @proactive_tier_assignment[:source],
                             provider: @resolved_provider, model: @resolved_model }.compact,
              duration_ms: 0,
              timestamp:   Time.now
            }
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
