# frozen_string_literal: true

require 'securerandom'
require 'legion/llm/routing_context'
require 'legion/llm/routing/settings_state'
require 'legion/llm/routing/header_constraints'

module Legion
  module LLM
    module Inference
      AUTO_ROUTING_MODEL_KEY = 'legionio'

      Request = ::Data.define(
        :id, :conversation_id, :idempotency_key, :schema_version,
        :system, :messages, :tools, :tool_choice,
        :routing, :tokens, :stop, :generation, :thinking,
        :response_format, :stream, :fork, :context_strategy,
        :cache, :priority, :ttl,
        :extra, :metadata, :enrichments, :predictions,
        :tracing, :classification, :caller, :agent,
        :billing, :test, :modality, :hooks,
        # SSOT v3 §7.2: trusted per-request routing context (server-created seed),
        # the sole body-model hint decision, the immutable routing settings
        # generation captured at ingress, and the trusted X-Legion-*/internal
        # constraints. `routing` is retained only as compatibility metadata.
        :routing_context, :body_model_hint_decision, :routing_settings_snapshot, :trusted_constraints
      ) do
        # N x N law: Inference::Request#messages is Array<Canonical::Message>.
        # Every pipeline entry (client translators, native/inference APIs,
        # daemon-internal chat) funnels through build; canonical objects pass
        # through, plain strings and wire hashes are translated to canonical at
        # this boundary, and anything else raises loudly. No hash-shaped
        # messages survive past this point.
        def self.canonicalize_messages(messages)
          Array(messages).map { |message| canonicalize_inbound_message(message) }
        end

        def self.canonicalize_inbound_message(message)
          canonical = Legion::Extensions::Llm::Canonical::Message
          return message if message.is_a?(canonical)
          return canonical.build(role: :user, content: message) if message.is_a?(String)
          return canonical.from_hash(message) if message.is_a?(Hash)

          raise ArgumentError,
                "Inference::Request messages must be Canonical::Message, String, or Hash, got #{message.class}"
        end

        # SSOT v3 §7.2 additive build order. `routing_context` is injected only by
        # build_for_test; otherwise a fresh server seed is created here. The new
        # trusted fields are always populated (derived from existing routing kwargs
        # when a caller has not yet migrated), so every Request carries them.
        def self.build(routing_context: nil, **kwargs)
          routing, extra = normalize_auto_routing(
            kwargs.fetch(:routing, { provider: nil, model: nil }),
            kwargs.fetch(:extra, {})
          )

          ctx = routing_context || Legion::LLM::RoutingContext.build
          settings_snapshot = kwargs[:routing_settings_snapshot] || Legion::LLM::Routing::SettingsState.current
          trusted = kwargs[:trusted_constraints] || trusted_from_routing(routing, settings_snapshot)

          # SSOT v4: the raw client body model is the sole input to the Router's
          # body-model-hint ladder, which reads it from metadata[:client_model].
          # Client translators pass it as the top-level client_model: kwarg, so
          # fold that into metadata here (the single bridge point) — the Request
          # no longer carries a precomputed body_model_hint_decision.
          metadata = kwargs.fetch(:metadata, {})
          metadata = metadata.merge(client_model: kwargs[:client_model]) unless kwargs[:client_model].nil?

          new(
            routing_context:           ctx,
            routing_settings_snapshot: settings_snapshot,
            trusted_constraints:       trusted,
            body_model_hint_decision:  nil,
            id:                        kwargs[:id] || "req_#{SecureRandom.hex(12)}",
            conversation_id:           kwargs[:conversation_id],
            idempotency_key:           kwargs[:idempotency_key],
            schema_version:            kwargs.fetch(:schema_version, '1.0.0'),
            system:                    kwargs[:system],
            messages:                  canonicalize_messages(kwargs.fetch(:messages, [])),
            tools:                     kwargs.key?(:tools) ? kwargs[:tools] : nil,
            tool_choice:               kwargs.fetch(:tool_choice, { mode: :auto }),
            routing:                   routing,
            tokens:                    kwargs.fetch(:tokens, { max: 4096 }),
            stop:                      kwargs.fetch(:stop, { sequences: [] }),
            generation:                kwargs.fetch(:generation, {}),
            thinking:                  kwargs[:thinking],
            response_format:           kwargs.fetch(:response_format, { type: :text }),
            stream:                    kwargs.fetch(:stream, false),
            fork:                      kwargs[:fork],
            context_strategy:          kwargs.fetch(:context_strategy, :auto),
            cache:                     kwargs.fetch(:cache, { strategy: :default, cacheable: true }),
            priority:                  kwargs.fetch(:priority, :normal),
            ttl:                       kwargs[:ttl],
            extra:                     extra,
            metadata:                  metadata,
            enrichments:               kwargs.fetch(:enrichments, {}),
            predictions:               kwargs.fetch(:predictions, {}),
            tracing:                   kwargs[:tracing],
            classification:            kwargs[:classification],
            caller:                    kwargs[:caller],
            agent:                     kwargs[:agent],
            billing:                   kwargs[:billing],
            test:                      kwargs[:test],
            modality:                  kwargs[:modality],
            hooks:                     kwargs[:hooks]
          )
        end

        def self.from_chat_args(**kwargs)
          request_id = kwargs[:request_id] || kwargs[:id]
          # Plain strings, wire hashes, and canonical objects are all translated
          # to Array<Canonical::Message> by build's canonicalize_messages.
          messages = kwargs[:messages] || kwargs[:message] || []

          routing = {
            provider: kwargs[:provider],
            model:    kwargs[:model]
          }

          extra = kwargs.except(
            :message, :messages, :model, :provider, :system,
            :tools, :tool_choice, :stream, :caller, :classification, :billing,
            :agent, :test, :tracing, :priority, :conversation_id,
            :request_id, :id, :generation, :thinking, :response_format,
            :context_strategy, :cache, :fork, :tokens, :stop,
            :modality, :hooks, :idempotency_key, :ttl, :metadata,
            :enrichments, :predictions
          )

          build_args = {
            messages:         messages,
            system:           kwargs[:system],
            routing:          routing,
            tools:            kwargs.key?(:tools) ? kwargs[:tools] : nil,
            tool_choice:      kwargs[:tool_choice] || { mode: :auto },
            stream:           kwargs.fetch(:stream, false),
            generation:       kwargs[:generation] || {},
            thinking:         kwargs[:thinking],
            response_format:  kwargs[:response_format] || { type: :text },
            context_strategy: kwargs.fetch(:context_strategy, :auto),
            cache:            kwargs[:cache] || { strategy: :default, cacheable: true },
            fork:             kwargs[:fork],
            tokens:           kwargs[:tokens] || { max: 4096 },
            stop:             kwargs[:stop] || { sequences: [] },
            modality:         kwargs[:modality],
            hooks:            kwargs[:hooks],
            caller:           kwargs[:caller],
            classification:   kwargs[:classification],
            billing:          kwargs[:billing],
            agent:            kwargs[:agent],
            test:             kwargs[:test],
            tracing:          kwargs[:tracing],
            priority:         kwargs.fetch(:priority, :normal),
            conversation_id:  kwargs[:conversation_id],
            idempotency_key:  kwargs[:idempotency_key],
            ttl:              kwargs[:ttl],
            metadata:         kwargs[:metadata] || {},
            enrichments:      kwargs[:enrichments] || {},
            predictions:      kwargs[:predictions] || {},
            extra:            extra
          }
          build_args[:id] = request_id if request_id
          build(**build_args)
        end

        # SSOT v3 §7.2 test helper: delegates to the production normalization
        # path, substituting only a deterministic RoutingContext. It cannot
        # bypass body policy, constraint derivation, or request freezing.
        def self.build_for_test(routing_seed:, **keywords)
          build(routing_context: Legion::LLM::RoutingContext.for_test(routing_seed: routing_seed), **keywords)
        end

        # Derive trusted constraints from a legacy `routing` hash for callers not
        # yet migrated to pass an explicit trusted_constraints value. The routing
        # hash is trusted internal input (not an untrusted client body field).
        def self.trusted_from_routing(routing, settings_snapshot)
          routing ||= {}
          instance = routing[:instance] || routing[:instance_id] || routing[:provider_instance]
          Legion::LLM::Routing::HeaderConstraints.from_internal(
            provider: routing[:provider], instance_id: instance, model: routing[:model],
            tier: routing[:tier], maximum_attempts: nil, settings_snapshot: settings_snapshot
          )
        end

        def self.auto_routing_model?(model)
          routing_settings = Legion::Settings.dig(:llm, :routing) || {}
          configured = routing_settings[:auto_routing_model_aliases]
          aliases = Array(configured).map { |entry| entry.to_s.strip.downcase }.reject(&:empty?)
          aliases = [AUTO_ROUTING_MODEL_KEY] if aliases.empty?
          aliases.include?(model.to_s.strip.downcase)
        end

        def self.default_auto_routing_intent
          intent = Legion::Settings[:llm][:routing][:default_intent]
          intent = intent.is_a?(Hash) ? normalize_hash(intent) : {}
          intent.merge(operation: :chat, effort: :moderate)
        end

        def self.normalize_auto_routing(routing, extra)
          normalized_routing = normalize_hash(routing)
          normalized_extra = normalize_hash(extra)
          return [normalized_routing, normalized_extra] unless auto_routing_model?(normalized_routing[:model])

          normalized_routing = normalized_routing.dup
          normalized_routing[:model] = nil
          normalized_extra = normalized_extra.dup
          normalized_extra[:requested_model_alias] = Legion::LLM::Inference::AUTO_ROUTING_MODEL_KEY
          if normalized_routing.values_at(:provider, :instance, :instance_id, :provider_instance).compact.any? ||
             normalized_extra[:tier]
            return [normalized_routing, normalized_extra]
          end

          normalized_extra[:intent] ||= default_auto_routing_intent
          normalized_extra[:auto_route] = true
          [normalized_routing, normalized_extra]
        end

        def self.normalize_hash(value)
          return {} unless value.is_a?(Hash)

          value.each_with_object({}) do |(key, hash_value), normalized|
            normalized[key.respond_to?(:to_sym) ? key.to_sym : key] = hash_value
          end
        end
      end
    end
  end
end
