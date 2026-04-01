# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Steps
        module PostResponse
          def step_post_response
            response = current_response

            AuditPublisher.publish(request: @request, response: response)

            @timeline.record(
              category: :audit, key: 'audit:publish',
              direction: :outbound, detail: 'published to llm.audit',
              from: 'pipeline', to: 'llm.audit'
            )
          rescue StandardError => e
            @warnings << "post_response error: #{e.message}"
          end

          private

          def extract_tokens
            return {} unless @raw_response.respond_to?(:input_tokens)

            input  = @raw_response.input_tokens.to_i
            output = @raw_response.output_tokens.to_i

            cache_read  = @raw_response.respond_to?(:cache_read_tokens) ? @raw_response.cache_read_tokens.to_i : 0
            cache_write = @raw_response.respond_to?(:cache_write_tokens) ? @raw_response.cache_write_tokens.to_i : 0

            Usage.new(
              input_tokens:       input,
              output_tokens:      output,
              cache_read_tokens:  cache_read,
              cache_write_tokens: cache_write
            )
          end

          def current_response
            msg = if @raw_response.respond_to?(:content)
                    { role: :assistant, content: @raw_response.content }
                  elsif @raw_response.is_a?(Hash) && @raw_response[:content]
                    @raw_response
                  else
                    { role: :assistant, content: @raw_response.to_s }
                  end

            Response.build(
              request_id:      @request.id,
              conversation_id: @request.conversation_id || "conv_#{SecureRandom.hex(8)}",
              message:         msg,
              routing:         { provider: @resolved_provider, model: @resolved_model },
              tokens:          extract_tokens,
              enrichments:     @enrichments,
              audit:           @audit,
              timeline:        @timeline.events,
              tracing:         @tracing,
              caller:          @request.caller,
              classification:  @request.classification
            )
          end
        end
      end
    end
  end
end
