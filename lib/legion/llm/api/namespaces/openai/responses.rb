# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'
require 'legion/llm/types'
require 'legion/llm/token_estimation'
require 'legion/llm/api/namespaces/helpers'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Responses
            extend Legion::Logging::Helper

            def self.registered(app) # rubocop:disable Metrics/AbcSize
              log.debug('[llm][api][namespaces][openai][responses] registering routes')

              app.post '/v1/responses' do
                require_llm!
                request_started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
                body = parse_request_body

                request_id = env['HTTP_X_CLIENT_REQUEST_ID'] || "resp_#{SecureRandom.hex(16)}"

                input = body[:input]
                messages = case input
                           when Array
                             Responses.normalize_input_array(input)
                           when String
                             [{ role: 'user', content: input }]
                           else
                             return openai_error('input is required (string or array)',
                                                 type: 'invalid_request_error', status_code: 400)
                           end

                messages = [{ role: 'system', content: body[:instructions].to_s }] + messages if body[:instructions]

                model       = body[:model] || Legion::Settings[:llm][:default_model] || 'default'
                streaming   = body[:stream] == true
                tool_decls  = Responses.build_tool_declarations(body[:tools])
                thinking    = Responses.extract_thinking_config(body)

                ext_provider = env['HTTP_X_LEGION_PROVIDER'] || body[:provider]
                ext_tier     = env['HTTP_X_LEGION_TIER']     || body[:tier]
                ext_instance = env['HTTP_X_LEGION_INSTANCE'] || body[:instance]

                routing = { provider: ext_provider, instance: ext_instance, model: model }.compact
                extra   = {}
                extra[:tier] = ext_tier.to_sym if ext_tier

                log.info("[llm][api][namespaces][openai][responses] action=accepted request_id=#{request_id} model=#{model} stream=#{streaming}")

                inference_request = Legion::LLM::Inference::Request.build(
                  id:              request_id,
                  messages:        messages,
                  routing:         routing,
                  tools:           tool_decls,
                  caller:          build_server_caller(source: 'openai_responses', path: request.path, env: env),
                  conversation_id: env['HTTP_X_LEGION_CONVERSATION_ID'] || env['HTTP_THREAD_ID'],
                  stream:          streaming,
                  thinking:        thinking,
                  cache:           { strategy: :default, cacheable: true },
                  extra:           extra.empty? ? {} : extra
                )
                executor = Legion::LLM::Inference::Executor.new(inference_request)

                if streaming
                  content_type 'text/event-stream'
                  headers 'Cache-Control' => 'no-cache', 'Connection' => 'keep-alive', 'X-Accel-Buffering' => 'no'
                  stream do |out|
                    pipeline_response = Responses.stream_response(out, executor, request_id: request_id, model: model, upstream_body: body)
                    tool_calls = Responses.build_output_tool_calls(pipeline_response)
                    log_api_completion_summary(
                      namespace:         'namespaces][openai][responses',
                      request_id:        request_id,
                      pipeline_response: pipeline_response,
                      stream:            true,
                      started_at:        request_started_at,
                      tool_calls:        tool_calls,
                      stop_reason:       tool_calls.any? ? 'requires_action' : 'completed'
                    )
                  rescue StandardError => e
                    handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.responses.stream', request_id: request_id)
                    out << "event: error\ndata: #{Legion::JSON.dump({ type: 'server_error', message: e.message })}\n\n"
                  end
                else
                  pipeline_response = Responses.call_executor_sync(executor, upstream_body: body)
                  response_body     = Responses.format_response(pipeline_response, request_id: request_id, model: model)
                  tool_calls = Responses.build_output_tool_calls(pipeline_response)
                  log_api_completion_summary(
                    namespace:         'namespaces][openai][responses',
                    request_id:        request_id,
                    pipeline_response: pipeline_response,
                    stream:            false,
                    started_at:        request_started_at,
                    tool_calls:        tool_calls,
                    stop_reason:       response_body[:status]
                  )
                  content_type :json
                  status 200
                  Legion::JSON.dump(response_body)
                end
              rescue Legion::LLM::AuthError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.responses.auth')
                openai_error(e.message, type: 'authentication_error', status_code: 401)
              rescue Legion::LLM::RateLimitError => e
                handle_exception(e, level: :warn, handled: true, operation: 'llm.api.namespaces.openai.responses.rate_limit')
                openai_error(e.message, type: 'rate_limit_error', code: 'rate_limit_exceeded', status_code: 429)
              rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.responses.provider')
                openai_error(e.message, type: 'server_error', status_code: 502)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.responses')
                openai_error(e.message, type: 'server_error', status_code: 500)
              end
              app.get '/v1/responses/:id' do
                log.debug("[llm][api][namespaces][openai][responses] action=retrieve id=#{params[:id]}")
                openai_error("Response '#{params[:id]}' not found", type: 'invalid_request_error',
                                                                    code: 'response_not_found', status_code: 404)
              end

              app.delete '/v1/responses/:id' do
                log.debug("[llm][api][namespaces][openai][responses] action=delete id=#{params[:id]}")
                content_type :json
                Legion::JSON.dump({ id: params[:id], object: 'response', deleted: true })
              end

              app.post '/v1/responses/:id/cancel' do
                log.debug("[llm][api][namespaces][openai][responses] action=cancel id=#{params[:id]}")
                openai_error("Response '#{params[:id]}' not found or already completed",
                             type: 'invalid_request_error', status_code: 404)
              end

              app.get '/v1/responses/:id/input_items' do
                log.debug("[llm][api][namespaces][openai][responses] action=input_items id=#{params[:id]}")
                content_type :json
                Legion::JSON.dump({ object: 'list', data: [], has_more: false })
              end

              app.post '/v1/responses/:id/input_tokens/count' do
                body  = parse_request_body
                input = body[:input]
                model = body[:model] || params[:id]
                messages = case input
                           when Array  then Responses.normalize_input_array(input)
                           when String then [{ role: 'user', content: input }]
                           else []
                           end
                result = Legion::LLM::TokenEstimation.estimate(messages: messages, model: model.to_s)
                content_type :json
                Legion::JSON.dump(result)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.responses.count_tokens')
                openai_error(e.message, type: 'server_error', status_code: 500)
              end

              app.post '/v1/responses/:id/compact' do
                log.debug("[llm][api][namespaces][openai][responses] action=compact id=#{params[:id]}")
                openai_error("Response '#{params[:id]}' not found", type: 'invalid_request_error', status_code: 404)
              end

              # Legacy alias — preserved for clients using the pre-namespace path.
              app.post '/api/llm/inference/v1/responses' do
                log.debug('[llm][api][namespaces][openai][responses] action=legacy_alias forwarding to /v1/responses handler')
                call env.merge('PATH_INFO' => '/v1/responses')
              end

              log.debug('[llm][api][namespaces][openai][responses] routes registered')
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.responses.register')
            end

            # --- Support methods ---

            def self.normalize_input_array(input)
              messages = []
              pending_tool_calls = []

              input.each do |item|
                item = item.transform_keys(&:to_sym) if item.respond_to?(:transform_keys)
                case item[:type]&.to_s
                when 'function_call'
                  pending_tool_calls << {
                    id:        item[:call_id] || item[:id],
                    name:      item[:name].to_s,
                    arguments: item[:arguments].is_a?(String) ? item[:arguments] : Legion::JSON.dump(item[:arguments] || {})
                  }
                when 'function_call_output'
                  flush_pending_tool_calls(messages, pending_tool_calls)
                  messages << { role: 'tool', tool_call_id: item[:call_id], content: item[:output].to_s }
                else
                  flush_pending_tool_calls(messages, pending_tool_calls)
                  role = item[:role]&.to_s
                  next unless role

                  # OpenAI Responses API uses "developer" as a higher-trust system role.
                  # All downstream providers only understand the standard four roles.
                  role = 'system' if role == 'developer'

                  content = item[:content]
                  content = content.to_s if content && !content.is_a?(Array)
                  messages << { role: role, content: content }.compact
                end
              end
              flush_pending_tool_calls(messages, pending_tool_calls)
              messages
            end

            def self.flush_pending_tool_calls(messages, pending)
              return if pending.empty?

              messages << {
                role:       'assistant',
                content:    '',
                tool_calls: pending.map do |tc|
                  { id: tc[:id], type: 'function', function: { name: tc[:name], arguments: tc[:arguments] } }
                end
              }
              pending.clear
            end

            # Extract thinking/reasoning config from OpenAI Responses API request.
            # OpenAI format: { reasoning: { effort: "low|medium|high" } }
            # Convert to Anthropic thinking config for downstream providers.
            def self.extract_thinking_config(body)
              reasoning = body[:reasoning] || body['reasoning']
              return nil unless reasoning

              effort = if reasoning.is_a?(Hash)
                         reasoning[:effort] || reasoning['effort']
                       else
                         reasoning
                       end

              # Budget must be strictly less than max_tokens (Anthropic constraint).
              # Use conservative defaults — test payloads typically use max_output_tokens: 2048.
              # Preserve the effort value so OpenAI-compatible providers can extract it
              # via openai_reasoning_effort(thinking), while Anthropic providers use budget_tokens.
              case effort.to_s
              when 'low'
                { type: 'enabled', budget_tokens: 512, effort: effort.to_s }
              when 'high', 'medium'
                { type: 'enabled', budget_tokens: 1024, effort: effort.to_s }
              end
            end

            def self.build_tool_declarations(tools)
              return [] unless tools.is_a?(Array) && !tools.empty?

              tools.filter_map do |tool|
                fn = nil
                t  = tool.respond_to?(:transform_keys) ? tool.transform_keys(&:to_sym) : tool
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
                tool_name = fn.is_a?(Hash) ? fn[:name] : nil
                Legion::Logging::Helper.log.warn("[llm][api][namespaces][openai][responses] build_tool failed name=#{tool_name} error=#{e.message}")
                nil
              end
            end

            def self.format_response(pipeline_response, request_id:, model:)
              routing       = pipeline_response.routing || {}
              tokens        = pipeline_response.tokens || {}
              raw_msg       = pipeline_response.message
              content       = raw_msg.is_a?(Hash) ? (raw_msg[:content] || raw_msg['content']).to_s : raw_msg.to_s
              resolved_model = (routing[:model] || routing['model'] || model).to_s
              tool_calls = build_output_tool_calls(pipeline_response)
              reasoning = build_output_reasoning(pipeline_response)

              output = [*reasoning, *tool_calls, {
                type:    'message',
                id:      "msg_#{SecureRandom.hex(12)}",
                role:    'assistant',
                content: [{ type: 'output_text', text: content }],
                status:  'completed'
              }]

              status = tool_calls.any? ? 'requires_action' : 'completed'

              result = { id: request_id, object: 'response', created_at: Time.now.to_i,
                model: resolved_model, output: output, usage: build_usage(tokens), status: status }

              if tool_calls.any?
                result[:action_required] = {
                  type:           'function_calls',
                  function_calls: tool_calls
                }
              end

              result
            end

            # rubocop:disable Metrics/AbcSize
            def self.stream_response(out, executor, request_id:, model:, upstream_body: nil)
              created_at = Time.now.to_i
              seq        = 0
              base_resp  = { id: request_id, object: 'response', created_at: created_at,
                             status: 'in_progress', model: model, output: [], usage: nil }

              out << sse('response.created',       { type: 'response.created',       sequence_number: seq += 1, response: base_resp })
              out << sse('response.in_progress',   { type: 'response.in_progress',   sequence_number: seq += 1, response: base_resp })

              msg_id = "msg_#{SecureRandom.hex(12)}"
              msg_index = 0
              message_opened = false
              output_items = []

              open_message = lambda do
                next if message_opened

                msg_index = output_items.length
                message_item = { id: msg_id, type: 'message', role: 'assistant', content: [], status: 'in_progress' }
                output_items << message_item
                out << sse('response.output_item.added',  { type: 'response.output_item.added',  sequence_number: seq += 1, output_index: msg_index,
                                                            item: message_item })
                out << sse('response.content_part.added', { type: 'response.content_part.added', sequence_number: seq += 1, output_index: msg_index,
                                                            content_index: 0, item_id: msg_id,
                                                            part: { type: 'output_text', text: '', annotations: [] } })
                message_opened = true
              end

              full_text = +''
              full_reasoning = +''
              pending_tool_calls = {} # id => { name:, arguments:, output_index: }
              pipeline_response = call_executor(executor, upstream_body: upstream_body) do |chunk|
                thinking = chunk.respond_to?(:thinking) ? extract_thinking_text(chunk.thinking) : ''
                unless thinking.empty?
                  full_reasoning << thinking
                  emit_reasoning_delta(out, request_id, output_items, thinking, sequence: -> { seq += 1 })
                end

                # Handle tool call deltas from streaming responses.
                # These emit SSE events in real-time so the client sees tool calls
                # as they arrive. At the end, build_output_tool_calls provides the
                # final consolidated list (which filters out server-executed tools).
                if chunk.respond_to?(:tool_calls) && chunk.tool_calls && !chunk.tool_calls.empty?
                  close_thinking_item(out, output_items, sequence: -> { seq += 1 })
                  chunk.tool_calls.each do |tc_id, tc|
                    tc_id_str = tc_id.to_s
                    tc_name = tc.respond_to?(:name) ? tc.name.to_s : ''
                    tc_args = tc.respond_to?(:arguments) ? tc.arguments.to_s : ''
                    next if tc_args.empty? && tc_name.empty?

                    unless pending_tool_calls[tc_id_str]
                      idx = output_items.length
                      out << sse('response.output_item.added',
                                 { type: 'response.output_item.added', sequence_number: seq += 1,
                                   output_index: idx, item: { id: tc_id_str, type: 'function_call', name: tc_name,
                                     call_id: tc_id_str, arguments: '', status: 'in_progress' } })
                      pending_tool_calls[tc_id_str] = { id: tc_id_str, name: tc_name, arguments: +'', output_index: idx }
                      output_items << { id: tc_id_str, type: 'function_call', name: tc_name,
                                        call_id: tc_id_str, arguments: pending_tool_calls[tc_id_str][:arguments], status: 'in_progress' }
                    end

                    pending_tc = pending_tool_calls[tc_id_str]
                    out << sse('response.function_call_arguments.delta',
                               { type: 'response.function_call_arguments.delta', sequence_number: seq += 1,
                                 output_index: pending_tc[:output_index], item_id: tc_id_str, delta: tc_args })
                    pending_tc[:arguments] << tc_args
                  end
                end

                text = chunk.respond_to?(:content) ? chunk.content.to_s : chunk.to_s
                next if text.empty?

                close_thinking_item(out, output_items, sequence: -> { seq += 1 })
                open_message.call
                full_text << text
                out << sse('response.output_text.delta', { type: 'response.output_text.delta', sequence_number: seq += 1,
                                                           output_index: msg_index, content_index: 0, item_id: msg_id, delta: text })
              end

              routing        = pipeline_response.routing || {}
              tokens         = pipeline_response.tokens  || {}
              resolved_model = (routing[:model] || routing['model'] || model).to_s
              usage          = build_usage(tokens)

              if full_reasoning.empty?
                final_reasoning = extract_thinking_text(pipeline_response.respond_to?(:thinking) ? pipeline_response.thinking : nil)
                unless final_reasoning.empty?
                  full_reasoning << final_reasoning
                  emit_reasoning_delta(out, request_id, output_items, final_reasoning, sequence: -> { seq += 1 })
                end
              end
              close_thinking_item(out, output_items, sequence: -> { seq += 1 })

              open_message.call
              out << sse('response.output_text.done',   { type: 'response.output_text.done',   sequence_number: seq += 1,
                                                          output_index: msg_index, content_index: 0, item_id: msg_id, text: full_text })
              out << sse('response.content_part.done',  { type: 'response.content_part.done',  sequence_number: seq += 1,
                                                          output_index: msg_index, content_index: 0, item_id: msg_id,
                                                          part: { type: 'output_text', text: full_text, annotations: [] } })

              completed_item = { id: msg_id, type: 'message', role: 'assistant', status: 'completed',
                                 content: [{ type: 'output_text', text: full_text, annotations: [] }] }
              out << sse('response.output_item.done', { type: 'response.output_item.done', sequence_number: seq += 1,
                                                        output_index: msg_index, item: completed_item })
              output_items[msg_index] = completed_item

              # Complete any pending streaming tool calls with their final arguments.
              pending_tool_calls.each_value do |pending|
                out << sse('response.function_call_arguments.done',
                           { type: 'response.function_call_arguments.done', sequence_number: seq += 1,
                             output_index: pending[:output_index], item_id: pending[:id],
                             arguments: pending[:arguments] })
                out << sse('response.output_item.done',
                           { type: 'response.output_item.done', sequence_number: seq += 1,
                             output_index: pending[:output_index],
                             item: { id: pending[:id], type: 'function_call', name: pending[:name],
                                     call_id: pending[:id], arguments: pending[:arguments], status: 'completed' } })
              end

              # Determine final status based on whether there are function calls
              # that require client-side execution. Per OpenAI Responses API spec,
              # the final event must be response.done (not response.completed) when
              # function calls need client execution.
              has_tool_calls = pending_tool_calls.any?
              out << if has_tool_calls
                       sse('response.done', { type: 'response.done', sequence_number: seq + 1,
                         response: { id: request_id, object: 'response', created_at: created_at,
                           status: 'requires_action', model: resolved_model,
                           output: output_items, usage: usage,
                           action_required: { type: 'function_calls', function_calls: output_items.select { |i| i[:type] == 'function_call' } } } })
                     else
                       sse('response.completed', { type: 'response.completed', sequence_number: seq + 1,
                         response: { id: request_id, object: 'response', created_at: created_at,
                           status: 'completed', model: resolved_model,
                           output: output_items, usage: usage } })
                     end
              pipeline_response
            end
            # rubocop:enable Metrics/AbcSize

            def self.call_executor(executor, upstream_body: nil, &)
              if executor.respond_to?(:call_responses)
                executor.call_responses(body: upstream_body, stream: true, &)
              else
                executor.call_stream(&)
              end
            end

            def self.call_executor_sync(executor, upstream_body: nil)
              if executor.respond_to?(:call_responses)
                executor.call_responses(body: upstream_body, stream: false)
              else
                executor.call
              end
            end

            def self.native_responses_supported?(executor, _upstream_body)
              executor.respond_to?(:call_responses)
            end

            def self.build_output_tool_calls(pipeline_response)
              tools_data = pipeline_response.respond_to?(:tools) ? pipeline_response.tools : nil
              return [] unless tools_data.is_a?(Array) && !tools_data.empty?

              tools_data.filter_map do |tc|
                name  = tc.respond_to?(:name) ? tc.name : (tc[:name] || tc['name'])
                args  = tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc['arguments'] || {})
                tc_id = tc.respond_to?(:id) ? tc.id : (tc[:id] || tc['id'] || "call_#{SecureRandom.hex(8)}")
                next unless name

                { type: 'function_call', id: "fc_#{SecureRandom.hex(12)}", call_id: tc_id,
                  name: name.to_s, arguments: args.is_a?(String) ? args : Legion::JSON.dump(args), status: 'completed' }
              end
            end

            def self.build_output_reasoning(pipeline_response)
              thinking_data = pipeline_response.respond_to?(:thinking) ? pipeline_response.thinking : nil
              log.info "[llm][responses] build_output_reasoning thinking_data=#{thinking_data.inspect}"
              text = extract_thinking_text(thinking_data)
              log.info "[llm][responses] build_output_reasoning extracted_text_length=#{text.length}"
              return [] if text.empty?

              # OpenAI Responses API format: type: "thinking" with thinking text field
              [
                {
                  type:     'thinking',
                  id:       "thnk_#{SecureRandom.hex(12)}",
                  thinking: text,
                  status:   'completed'
                }
              ]
            end

            def self.emit_reasoning_delta(out, _request_id, output_items, text, sequence:)
              return if text.empty?

              state = current_thinking_state(output_items)
              unless state
                state = {
                  type:     'thinking',
                  id:       "thnk_#{SecureRandom.hex(12)}",
                  thinking: +'',
                  status:   'in_progress'
                }
                output_items << state
                output_index = output_items.length - 1
                out << sse('response.output_item.added',
                           { type: 'response.output_item.added', sequence_number: sequence.call,
                             output_index: output_index, item: state })
                out << sse('response.thinking_part.added',
                           { type: 'response.thinking_part.added', sequence_number: sequence.call,
                             output_index: output_index, item_id: state[:id],
                             part: { type: 'thinking', thinking: '' } })
              end

              output_index = output_items.index(state)
              state[:thinking] << text
              out << sse('response.thinking.delta',
                         { type: 'response.thinking.delta', sequence_number: sequence.call,
                           output_index: output_index, item_id: state[:id], delta: text })
            end

            def self.close_thinking_item(out, output_items, sequence:)
              state = current_thinking_state(output_items)
              return unless state && state[:status] == 'in_progress'

              output_index = output_items.index(state)
              state[:status] = 'completed'
              text = state[:thinking].to_s
              out << sse('response.thinking.done',
                         { type: 'response.thinking.done', sequence_number: sequence.call,
                           output_index: output_index, item_id: state[:id], text: text })
              out << sse('response.thinking_part.done',
                         { type: 'response.thinking_part.done', sequence_number: sequence.call,
                           output_index: output_index, item_id: state[:id],
                           part: { type: 'thinking', thinking: text } })
              out << sse('response.output_item.done',
                         { type: 'response.output_item.done', sequence_number: sequence.call,
                           output_index: output_index, item: state })
            end

            def self.current_thinking_state(output_items)
              output_items.find { |item| item[:type] == 'thinking' && item[:status] == 'in_progress' }
            end

            def self.extract_thinking_text(value)
              return '' if value.nil?
              return value.to_s if value.is_a?(String)

              if value.is_a?(Hash)
                normalized = value.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                text = normalized[:content] || normalized[:text] || normalized[:thinking] || normalized[:reasoning]
                return text.to_s if text
              end

              return value.content.to_s if value.respond_to?(:content) && value.content
              return value.text.to_s if value.respond_to?(:text) && value.text

              value.to_s
            end

            def self.build_usage(tokens)
              i = extract_token(tokens, :input_tokens)
              o = extract_token(tokens, :output_tokens)
              result = { input_tokens: i, output_tokens: o, total_tokens: i + o }
              # Preserve output token breakdown (e.g. reasoning_tokens from Responses API)
              details = tokens[:output_tokens_details] || tokens['output_tokens_details']
              result[:output_tokens_details] = details if details.is_a?(Hash) && !details.empty?
              result
            end

            def self.extract_token(tokens, key)
              return 0 if tokens.nil?

              if tokens.is_a?(Hash)
                v = tokens[key] || tokens[key.to_s]
                return v.to_i unless v.nil?

                alt = key == :input_tokens ? :input : :output
                v2  = tokens[alt] || tokens[alt.to_s]
                return v2.to_i unless v2.nil?

                return 0
              end

              method_name = { input_tokens: :input_tokens, output_tokens: :output_tokens,
                              input: :input_tokens, output: :output_tokens }[key]
              return tokens.public_send(method_name).to_i if method_name && tokens.respond_to?(method_name)

              0
            end

            def self.sse(name, payload)
              "event: #{name}\ndata: #{Legion::JSON.dump(payload)}\n\n"
            end
          end
        end
      end
    end
  end
end
