# frozen_string_literal: true

module Legion
  module LLM
    module Inference
      AUTO_ROUTING_MODEL_KEY = 'legionio'
      AUTO_ROUTING_MODEL_ALIASES = [AUTO_ROUTING_MODEL_KEY].freeze

      Request = ::Data.define(
        :id, :conversation_id, :idempotency_key, :schema_version,
        :system, :messages, :tools, :tool_choice,
        :routing, :tokens, :stop, :generation, :thinking,
        :response_format, :stream, :fork, :context_strategy,
        :cache, :priority, :ttl,
        :extra, :metadata, :enrichments, :predictions,
        :tracing, :classification, :caller, :agent,
        :billing, :test, :modality, :hooks
      ) do
        def self.build(**kwargs)
          routing, extra = normalize_auto_routing(
            kwargs.fetch(:routing, { provider: nil, model: nil }),
            kwargs.fetch(:extra, {})
          )

          new(
            id:               kwargs[:id] || "req_#{SecureRandom.hex(12)}",
            conversation_id:  kwargs[:conversation_id],
            idempotency_key:  kwargs[:idempotency_key],
            schema_version:   kwargs.fetch(:schema_version, '1.0.0'),
            system:           kwargs[:system],
            messages:         kwargs.fetch(:messages, []),
            tools:            kwargs.key?(:tools) ? kwargs[:tools] : nil,
            tool_choice:      kwargs.fetch(:tool_choice, { mode: :auto }),
            routing:          routing,
            tokens:           kwargs.fetch(:tokens, { max: 4096 }),
            stop:             kwargs.fetch(:stop, { sequences: [] }),
            generation:       kwargs.fetch(:generation, {}),
            thinking:         kwargs[:thinking],
            response_format:  kwargs.fetch(:response_format, { type: :text }),
            stream:           kwargs.fetch(:stream, false),
            fork:             kwargs[:fork],
            context_strategy: kwargs.fetch(:context_strategy, :auto),
            cache:            kwargs.fetch(:cache, { strategy: :default, cacheable: true }),
            priority:         kwargs.fetch(:priority, :normal),
            ttl:              kwargs[:ttl],
            extra:            extra,
            metadata:         kwargs.fetch(:metadata, {}),
            enrichments:      kwargs.fetch(:enrichments, {}),
            predictions:      kwargs.fetch(:predictions, {}),
            tracing:          kwargs[:tracing],
            classification:   kwargs[:classification],
            caller:           kwargs[:caller],
            agent:            kwargs[:agent],
            billing:          kwargs[:billing],
            test:             kwargs[:test],
            modality:         kwargs[:modality],
            hooks:            kwargs[:hooks]
          )
        end

        def self.from_chat_args(**kwargs)
          request_id = kwargs[:request_id] || kwargs[:id]
          messages = []
          if kwargs[:messages]
            messages = kwargs[:messages]
          elsif kwargs[:message]
            msg = kwargs[:message]
            messages = msg.is_a?(Array) ? msg : [{ role: :user, content: msg }]
          end

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

        def self.auto_routing_model?(model)
          Legion::LLM::Inference::AUTO_ROUTING_MODEL_ALIASES.include?(model.to_s.strip.downcase)
        end

        def self.default_auto_routing_intent
          intent = Legion::Settings[:llm][:routing][:default_intent]
          intent = intent.is_a?(Hash) ? normalize_hash(intent) : {}
          if intent.key?(:capability)
            raise ArgumentError,
                  'routing settings default_intent contains :capability which was removed; use :operation and :effort'
          end
          intent.merge(operation: :chat, effort: :moderate)
        end

        def self.normalize_auto_routing(routing, extra)
          normalized_routing = normalize_hash(routing)
          normalized_extra = normalize_hash(extra)
          return [normalized_routing, normalized_extra] unless auto_routing_model?(normalized_routing[:model])

          normalized_routing = { provider: nil, model: nil }
          normalized_extra = normalized_extra.dup
          normalized_extra.delete(:tier)
          normalized_extra[:intent] ||= default_auto_routing_intent
          normalized_extra[:auto_route] = true
          normalized_extra[:requested_model_alias] = Legion::LLM::Inference::AUTO_ROUTING_MODEL_KEY
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
