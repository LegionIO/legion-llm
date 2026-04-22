# frozen_string_literal: true

module Legion
  module LLM
    module Inference
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
          new(
            id:               kwargs[:id] || "req_#{SecureRandom.hex(12)}",
            conversation_id:  kwargs[:conversation_id],
            idempotency_key:  kwargs[:idempotency_key],
            schema_version:   kwargs.fetch(:schema_version, '1.0.0'),
            system:           kwargs[:system],
            messages:         kwargs.fetch(:messages, []),
            tools:            kwargs.key?(:tools) ? kwargs[:tools] : nil,
            tool_choice:      kwargs.fetch(:tool_choice, { mode: :auto }),
            routing:          kwargs.fetch(:routing, { provider: nil, model: nil }),
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
            extra:            kwargs.fetch(:extra, {}),
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
      end
    end
  end
end
