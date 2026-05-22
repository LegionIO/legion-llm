# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'
require 'legion/llm/types'

module Legion
  module LLM
    module API
      module OpenAI
        module Responses
          extend Legion::Logging::Helper

          def self.registered(app)
            log.debug('[llm][api][openai][responses] registering POST /v1/responses + /api/llm/inference/v1/responses')

            handler = build_handler

            app.post('/v1/responses') { instance_exec(&handler) }
            app.post('/api/llm/inference/v1/responses') { instance_exec(&handler) }

            log.debug('[llm][api][openai][responses] routes registered')
          end

          def self.build_handler # rubocop:disable Metrics/MethodLength
            proc do # rubocop:disable Metrics/BlockLength
              require_llm!
              body = parse_request_body
              request_id = "resp_#{SecureRandom.hex(16)}"

              input = body[:input]
              messages = case input
                         when Array
                           Responses.normalize_input_array(input)
                         when String
                           [{ role: 'user', content: input }]
                         else
                           halt 400, { 'Content-Type' => 'application/json' },
                                Legion::JSON.dump({ error: { message: 'input is required (string or array)',
                                                             type: 'invalid_request_error', code: nil } })
                         end

              messages = [{ role: 'system', content: body[:instructions].to_s }] + messages if body[:instructions]

              model = body[:model] || Legion::LLM::Settings.value(:default_model) || 'default'
              streaming = body[:stream] == true

              tool_declarations = Responses.build_tool_declarations(body[:tools])

              log.info(
                "[llm][api][openai][responses] action=accepted request_id=#{request_id} " \
                "model=#{model} stream=#{streaming} tools=#{tool_declarations.size}"
              )

              effective_caller = build_server_caller(source: 'openai_responses', path: request.path, env: env)

              require 'legion/llm/inference/request' unless defined?(Legion::LLM::Inference::Request)
              require 'legion/llm/inference/executor' unless defined?(Legion::LLM::Inference::Executor)

              inference_request = Legion::LLM::Inference::Request.build(
                id:       request_id,
                messages: messages,
                routing:  { model: model },
                tools:    tool_declarations,
                caller:   effective_caller,
                stream:   streaming,
                cache:    { strategy: :default, cacheable: true }
              )

              executor = Legion::LLM::Inference::Executor.new(inference_request)

              if streaming
                content_type 'text/event-stream'
                headers 'Cache-Control'     => 'no-cache',
                        'Connection'        => 'keep-alive',
                        'X-Accel-Buffering' => 'no'

                stream do |out|
                  Responses.stream_response(out, executor, request_id: request_id, model: model, upstream_body: body)
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.responses.stream', request_id: request_id)
                  out << "event: error\ndata: #{Legion::JSON.dump({ type: 'server_error', message: e.message })}\n\n"
                end
              else
                pipeline_response = executor.call_responses(body: body, stream: false)
                response_body = Responses.format_response(pipeline_response, request_id: request_id, model: model)

                log.info("[llm][api][openai][responses] action=complete request_id=#{request_id} model=#{response_body[:model]}")
                content_type :json
                status 200
                Legion::JSON.dump(response_body)
              end
            rescue Legion::LLM::AuthError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.responses.auth')
              halt 401, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'authentication_error' } })
            rescue Legion::LLM::RateLimitError => e
              handle_exception(e, level: :warn, handled: true, operation: 'llm.api.openai.responses.rate_limit')
              halt 429, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'rate_limit_error' } })
            rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.responses.provider')
              halt 502, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.responses')
              halt 500, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })
            end
          end

          def self.normalize_input_array(input)
            input.filter_map do |item|
              item = item.transform_keys(&:to_sym) if item.respond_to?(:transform_keys)

              case item[:type]&.to_s
              when 'function_call_output'
                { role: 'tool', tool_call_id: item[:call_id], content: item[:output].to_s }
              else
                role = item[:role]&.to_s
                next unless role

                content = item[:content]
                content = content.to_s if content && !content.is_a?(Array)
                { role: role, content: content }.compact
              end
            end
          end

          def self.build_tool_declarations(tools)
            return [] if tools.nil? || !tools.is_a?(Array) || tools.empty?

            tools.filter_map do |tool|
              t = tool.respond_to?(:transform_keys) ? tool.transform_keys(&:to_sym) : tool
              fn = t[:function] || t
              fn = fn.transform_keys(&:to_sym) if fn.respond_to?(:transform_keys)
              next unless fn[:name].to_s.length.positive?

              Legion::LLM::Types::ToolDefinition.build(
                name:        fn[:name].to_s,
                description: fn[:description].to_s,
                parameters:  fn[:parameters] || {},
                source:      { type: :client, executable: true }
              )
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'llm.api.openai.responses.build_tool')
              nil
            end
          end

          def self.format_response(pipeline_response, request_id:, model:)
            routing = pipeline_response.routing || {}
            tokens = pipeline_response.tokens || {}
            raw_msg = pipeline_response.message
            content = raw_msg.is_a?(Hash) ? (raw_msg[:content] || raw_msg['content']).to_s : raw_msg.to_s
            resolved_model = (routing[:model] || routing['model'] || model).to_s

            output = []

            tool_calls = build_output_tool_calls(pipeline_response)
            output.concat(tool_calls)

            output << {
              type:    'message',
              id:      "msg_#{SecureRandom.hex(12)}",
              role:    'assistant',
              content: [{ type: 'output_text', text: content }],
              status:  'completed'
            }

            {
              id:         request_id,
              object:     'response',
              created_at: Time.now.to_i,
              model:      resolved_model,
              output:     output,
              usage:      build_usage(tokens),
              status:     'completed'
            }
          end

          def self.stream_response(out, executor, request_id:, model:, upstream_body: nil) # rubocop:disable Metrics/MethodLength
            created_at = Time.now.to_i
            seq = 0
            in_progress_response = { id: request_id, object: 'response', created_at: created_at,
                                     status: 'in_progress', model: model, output: [], usage: nil }

            # response.created — envelope matches gateway format: { type:, response:, sequence_number: }
            out << sse_event('response.created', {
                               type:            'response.created',
                               sequence_number: seq += 1,
                               response:        in_progress_response
                             })

            out << sse_event('response.in_progress', {
                               type:            'response.in_progress',
                               sequence_number: seq += 1,
                               response:        in_progress_response
                             })

            msg_id = "msg_#{SecureRandom.hex(12)}"
            out << sse_event('response.output_item.added', {
                               type:            'response.output_item.added',
                               sequence_number: seq += 1,
                               output_index:    0,
                               item:            { id: msg_id, type: 'message', role: 'assistant',
                                 content: [], status: 'in_progress' }
                             })

            out << sse_event('response.content_part.added', {
                               type:            'response.content_part.added',
                               sequence_number: seq += 1,
                               output_index:    0,
                               content_index:   0,
                               item_id:         msg_id,
                               part:            { type: 'output_text', text: '', annotations: [] }
                             })

            full_text = +''

            pipeline_response = call_streaming_executor(executor, upstream_body: upstream_body) do |chunk|
              text = chunk.respond_to?(:content) ? chunk.content.to_s : chunk.to_s
              next if text.empty?

              full_text << text
              out << sse_event('response.output_text.delta', {
                                 type:            'response.output_text.delta',
                                 sequence_number: seq += 1,
                                 output_index:    0,
                                 content_index:   0,
                                 item_id:         msg_id,
                                 delta:           text
                               })
            end

            routing = pipeline_response.routing || {}
            tokens  = pipeline_response.tokens || {}
            resolved_model = (routing[:model] || routing['model'] || model).to_s
            usage = build_usage(tokens)

            out << sse_event('response.output_text.done', {
                               type:            'response.output_text.done',
                               sequence_number: seq += 1,
                               output_index:    0,
                               content_index:   0,
                               item_id:         msg_id,
                               text:            full_text
                             })

            out << sse_event('response.content_part.done', {
                               type:            'response.content_part.done',
                               sequence_number: seq += 1,
                               output_index:    0,
                               content_index:   0,
                               item_id:         msg_id,
                               part:            { type: 'output_text', text: full_text, annotations: [] }
                             })

            completed_item = { id: msg_id, type: 'message', role: 'assistant', status: 'completed',
                               content: [{ type: 'output_text', text: full_text, annotations: [] }] }
            out << sse_event('response.output_item.done', {
                               type:            'response.output_item.done',
                               sequence_number: seq += 1,
                               output_index:    0,
                               item:            completed_item
                             })

            out << sse_event('response.completed', {
                               type:            'response.completed',
                               sequence_number: seq + 1,
                               response:        {
                                 id:         request_id,
                                 object:     'response',
                                 created_at: created_at,
                                 status:     'completed',
                                 model:      resolved_model,
                                 output:     [completed_item],
                                 usage:      usage
                               }
                             })

            log.info("[llm][api][openai][responses] action=stream_complete request_id=#{request_id} model=#{resolved_model}")
          end

          def self.call_streaming_executor(executor, upstream_body: nil, &)
            if upstream_body && executor.respond_to?(:call_responses)
              executor.call_responses(body: upstream_body, stream: true, &)
            else
              executor.call_stream(&)
            end
          end

          def self.sse_event(name, payload)
            "event: #{name}\ndata: #{Legion::JSON.dump(payload)}\n\n"
          end

          def self.build_output_tool_calls(pipeline_response)
            tools_data = pipeline_response.respond_to?(:tools) ? pipeline_response.tools : nil
            return [] unless tools_data.is_a?(Array) && !tools_data.empty?

            tools_data.filter_map do |tc|
              name = tc.respond_to?(:name) ? tc.name : (tc[:name] || tc['name'])
              args = tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc['arguments'] || {})
              tc_id = tc.respond_to?(:id) ? tc.id : (tc[:id] || tc['id'] || "call_#{SecureRandom.hex(8)}")
              next unless name

              {
                type:      'function_call',
                id:        "fc_#{SecureRandom.hex(12)}",
                call_id:   tc_id,
                name:      name.to_s,
                arguments: args.is_a?(String) ? args : Legion::JSON.dump(args),
                status:    'completed'
              }
            end
          end

          def self.extract_token(tokens, key)
            return 0 if tokens.nil?

            aliases = token_aliases(key)

            if tokens.is_a?(Hash)
              aliases.each do |candidate|
                value = tokens[candidate]
                value = tokens[candidate.to_s] if value.nil?
                return value.to_i unless value.nil?
              end

              return 0
            end

            aliases.each do |candidate|
              method_name = token_method(candidate)
              return tokens.public_send(method_name).to_i if method_name && tokens.respond_to?(method_name)
            end

            0
          end

          def self.build_usage(tokens)
            input_tokens = extract_token(tokens, :input_tokens)
            output_tokens = extract_token(tokens, :output_tokens)

            {
              input_tokens:  input_tokens,
              output_tokens: output_tokens,
              total_tokens:  input_tokens + output_tokens
            }
          end

          def self.token_aliases(key)
            case key.to_sym
            when :input, :input_tokens
              %i[input_tokens input]
            when :output, :output_tokens
              %i[output_tokens output]
            else
              [key.to_sym]
            end
          end

          def self.token_method(key)
            {
              input:         :input_tokens,
              input_tokens:  :input_tokens,
              output:        :output_tokens,
              output_tokens: :output_tokens
            }[key.to_sym]
          end
        end
      end
    end
  end
end
