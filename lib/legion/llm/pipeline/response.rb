# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      Response = ::Data.define(
        :id, :request_id, :conversation_id, :schema_version,
        :message, :routing, :tokens, :thinking, :stop, :tools,
        :stream, :cache, :retry, :timestamps, :cost, :quality,
        :validation, :safety, :rate_limit, :features, :deprecation,
        :enrichments, :predictions, :audit, :timeline, :participants,
        :warnings, :wire, :tracing, :caller, :classification,
        :agent, :billing, :test
      ) do
        def self.build(**kwargs)
          new(
            id:              kwargs.fetch(:id) { "resp_#{SecureRandom.hex(12)}" },
            request_id:      kwargs.fetch(:request_id),
            conversation_id: kwargs.fetch(:conversation_id),
            schema_version:  kwargs.fetch(:schema_version, '1.0.0'),
            message:         kwargs.fetch(:message),
            routing:         kwargs.fetch(:routing, {}),
            tokens:          kwargs.fetch(:tokens, {}),
            thinking:        kwargs[:thinking],
            stop:            kwargs.fetch(:stop, {}),
            tools:           kwargs.fetch(:tools, []),
            stream:          kwargs.fetch(:stream, false),
            cache:           kwargs.fetch(:cache, {}),
            retry:           kwargs[:retry],
            timestamps:      kwargs.fetch(:timestamps, {}),
            cost:            kwargs.fetch(:cost, {}),
            quality:         kwargs[:quality],
            validation:      kwargs[:validation],
            safety:          kwargs[:safety],
            rate_limit:      kwargs[:rate_limit],
            features:        kwargs[:features],
            deprecation:     kwargs[:deprecation],
            enrichments:     kwargs.fetch(:enrichments, {}),
            predictions:     kwargs.fetch(:predictions, {}),
            audit:           kwargs.fetch(:audit, {}),
            timeline:        kwargs.fetch(:timeline, []),
            participants:    kwargs.fetch(:participants, []),
            warnings:        kwargs.fetch(:warnings, []),
            wire:            kwargs[:wire],
            tracing:         kwargs[:tracing],
            caller:          kwargs[:caller],
            classification:  kwargs[:classification],
            agent:           kwargs[:agent],
            billing:         kwargs[:billing],
            test:            kwargs[:test]
          )
        end

        def self.from_ruby_llm(msg, request_id:, conversation_id:, provider: nil, model: nil, **extra)
          input  = msg.respond_to?(:input_tokens) ? msg.input_tokens.to_i : 0
          output = msg.respond_to?(:output_tokens) ? msg.output_tokens.to_i : 0

          stop_reason = if msg.respond_to?(:stop_reason)
                          msg.stop_reason&.to_sym || :end_turn
                        elsif msg.respond_to?(:tool_calls) && msg.tool_calls&.any?
                          :tool_use
                        else
                          :end_turn
                        end

          build(
            request_id:      request_id,
            conversation_id: conversation_id,
            message:         { role: :assistant, content: msg.content },
            routing:         { provider: provider, model: model || (msg.respond_to?(:model_id) ? msg.model_id : nil) },
            tokens:          { input: input, output: output, total: input + output },
            stop:            { reason: stop_reason },
            **extra
          )
        end

        def with(**updates)
          self.class.build(**to_h, **updates)
        end
      end
    end
  end
end
