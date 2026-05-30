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

            def self.registered(app) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
              log.debug('[llm][api][namespaces][openai][responses] registering routes')

              # rubocop:disable Metrics/BlockLength
              app.post '/v1/responses' do
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
                             return openai_error('input is required (string or array)',
                                                 type: 'invalid_request_error', status_code: 400)
                           end

                messages = [{ role: 'system', content: body[:instructions].to_s }] + messages if body[:instructions]

                model       = body[:model] || Legion::LLM::Settings.value(:default_model) || 'default'
                streaming   = body[:stream] == true
                tool_decls  = Responses.build_tool_declarations(body[:tools])

                log.info("[llm][api][namespaces][openai][responses] action=accepted request_id=#{request_id} model=#{model} stream=#{streaming}")

                inference_request = Legion::LLM::Inference::Request.build(
                  id:       request_id,
                  messages: messages,
                  routing:  { model: model },
                  tools:    tool_decls,
                  caller:   build_server_caller(source: 'openai_responses', path: request.path, env: env),
                  stream:   streaming,
                  cache:    { strategy: :default, cacheable: true }
                )
                executor = Legion::LLM::Inference::Executor.new(inference_request)

                if streaming
                  content_type 'text/event-stream'
                  headers 'Cache-Control' => 'no-cache', 'Connection' => 'keep-alive', 'X-Accel-Buffering' => 'no'
                  stream do |out|
                    Responses.stream_response(out, executor, request_id: request_id, model: model, upstream_body: body)
                  rescue StandardError => e
                    handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.responses.stream', request_id: request_id)
                    out << "event: error\ndata: #{Legion::JSON.dump({ type: 'server_error', message: e.message })}\n\n"
                  end
                else
                  pipeline_response = executor.call_responses(body: body, stream: false)
                  response_body     = Responses.format_response(pipeline_response, request_id: request_id, model: model)
                  log.info("[llm][api][namespaces][openai][responses] action=complete request_id=#{request_id}")
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
              # rubocop:enable Metrics/BlockLength

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

              output = [*tool_calls, {
                type:    'message',
                id:      "msg_#{SecureRandom.hex(12)}",
                role:    'assistant',
                content: [{ type: 'output_text', text: content }],
                status:  'completed'
              }]

              { id: request_id, object: 'response', created_at: Time.now.to_i,
                model: resolved_model, output: output, usage: build_usage(tokens), status: 'completed' }
            end

            def self.stream_response(out, executor, request_id:, model:, upstream_body: nil)
              created_at = Time.now.to_i
              seq        = 0
              base_resp  = { id: request_id, object: 'response', created_at: created_at,
                             status: 'in_progress', model: model, output: [], usage: nil }

              out << sse('response.created',       { type: 'response.created',       sequence_number: seq += 1, response: base_resp })
              out << sse('response.in_progress',   { type: 'response.in_progress',   sequence_number: seq += 1, response: base_resp })

              msg_id = "msg_#{SecureRandom.hex(12)}"
              out << sse('response.output_item.added',  { type: 'response.output_item.added',  sequence_number: seq += 1, output_index: 0,
                                                          item: { id: msg_id, type: 'message', role: 'assistant', content: [], status: 'in_progress' } })
              out << sse('response.content_part.added', { type: 'response.content_part.added', sequence_number: seq += 1, output_index: 0,
                                                          content_index: 0, item_id: msg_id,
                                                          part: { type: 'output_text', text: '', annotations: [] } })

              full_text = +''
              pipeline_response = call_executor(executor, upstream_body: upstream_body) do |chunk|
                text = chunk.respond_to?(:content) ? chunk.content.to_s : chunk.to_s
                next if text.empty?

                full_text << text
                out << sse('response.output_text.delta', { type: 'response.output_text.delta', sequence_number: seq += 1,
                                                           output_index: 0, content_index: 0, item_id: msg_id, delta: text })
              end

              routing        = pipeline_response.routing || {}
              tokens         = pipeline_response.tokens  || {}
              resolved_model = (routing[:model] || routing['model'] || model).to_s
              usage          = build_usage(tokens)
              function_calls = build_output_tool_calls(pipeline_response)

              out << sse('response.output_text.done',   { type: 'response.output_text.done',   sequence_number: seq += 1,
                                                          output_index: 0, content_index: 0, item_id: msg_id, text: full_text })
              out << sse('response.content_part.done',  { type: 'response.content_part.done',  sequence_number: seq += 1,
                                                          output_index: 0, content_index: 0, item_id: msg_id,
                                                          part: { type: 'output_text', text: full_text, annotations: [] } })

              completed_item = { id: msg_id, type: 'message', role: 'assistant', status: 'completed',
                                 content: [{ type: 'output_text', text: full_text, annotations: [] }] }
              out << sse('response.output_item.done', { type: 'response.output_item.done', sequence_number: seq += 1,
                                                        output_index: 0, item: completed_item })

              function_calls.each_with_index do |fc, idx|
                oi = idx + 1
                out << sse('response.output_item.added',
                           { type: 'response.output_item.added', sequence_number: seq += 1, output_index: oi,
            item: fc.merge(status: 'in_progress', arguments: '') })
                out << sse('response.function_call_arguments.delta',
                           { type: 'response.function_call_arguments.delta', sequence_number: seq += 1, output_index: oi, item_id: fc[:id],
            delta: fc[:arguments] })
                out << sse('response.function_call_arguments.done',
                           { type: 'response.function_call_arguments.done',  sequence_number: seq += 1, output_index: oi, item_id: fc[:id],
            arguments: fc[:arguments] })
                out << sse('response.output_item.done',
                           { type: 'response.output_item.done',              sequence_number: seq += 1, output_index: oi, item: fc })
              end

              out << sse('response.completed', { type: 'response.completed', sequence_number: seq + 1,
                                                 response: { id: request_id, object: 'response', created_at: created_at,
                                                             status: 'completed', model: resolved_model,
                                                             output: [completed_item, *function_calls], usage: usage } })
            end

            def self.call_executor(executor, upstream_body: nil, &)
              if upstream_body && executor.respond_to?(:call_responses)
                executor.call_responses(body: upstream_body, stream: true, &)
              else
                executor.call_stream(&)
              end
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

            def self.build_usage(tokens)
              i = extract_token(tokens, :input_tokens)
              o = extract_token(tokens, :output_tokens)
              { input_tokens: i, output_tokens: o, total_tokens: i + o }
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
