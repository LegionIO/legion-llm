# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      Request = Data.define(
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
            id:               kwargs.fetch(:id) { "req_#{SecureRandom.hex(12)}" },
            conversation_id:  kwargs[:conversation_id],
            idempotency_key:  kwargs[:idempotency_key],
            schema_version:   kwargs.fetch(:schema_version, '1.0.0'),
            system:           kwargs[:system],
            messages:         kwargs.fetch(:messages, []),
            tools:            kwargs.fetch(:tools, []),
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
            :tools, :stream, :caller, :classification, :billing,
            :agent, :test, :tracing, :priority, :conversation_id
          )

          build(
            messages:        messages,
            system:          kwargs[:system],
            routing:         routing,
            tools:           kwargs.fetch(:tools, []),
            stream:          kwargs.fetch(:stream, false),
            caller:          kwargs[:caller],
            classification:  kwargs[:classification],
            billing:         kwargs[:billing],
            agent:           kwargs[:agent],
            test:            kwargs[:test],
            tracing:         kwargs[:tracing],
            priority:        kwargs.fetch(:priority, :normal),
            conversation_id: kwargs[:conversation_id],
            extra:           extra
          )
        end
      end
    end
  end
end
