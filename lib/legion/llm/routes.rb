# frozen_string_literal: true

# Self-registering route module for legion-llm.
# All routes previously defined in LegionIO/lib/legion/api/llm.rb now live here
# and are mounted via Legion::API.register_library_routes when legion-llm boots.
#
# LegionIO/lib/legion/api/llm.rb is preserved for backward compatibility but guards
# its registration with defined?(Legion::LLM::Routes) so double-registration is avoided.

require 'securerandom'
require 'open3'
require 'time'
require 'legion/logging/helper'

module Legion
  module LLM
    module Routes
      # Mixin for dynamically-built client tool classes — keeps build_client_tool_class small.
      module ClientToolMethods
        private

        def log_tool(level, ref, status, **details)
          return unless defined?(Legion::Logging)

          parts = ["[tool][#{ref}] #{status}"]
          details.each { |k, v| parts << "#{k}=#{v}" }
          Legion::Logging.send(level, parts.join(' '))
        end

        def summarize_tool_args(ref, kwargs)
          case ref
          when 'sh'
            { command: (kwargs[:command] || kwargs[:cmd] || kwargs.values.first).to_s[0, 200] }
          when 'file_read', 'list_directory'
            { path: (kwargs[:path] || kwargs[:file_path] || kwargs[:dir] || kwargs.values.first).to_s }
          when 'file_write'
            { path: (kwargs[:path] || kwargs[:file_path]).to_s, bytes: kwargs[:content].to_s.bytesize }
          when 'file_edit'
            { path: (kwargs[:path] || kwargs[:file_path]).to_s,
              old_len: kwargs[:old_text].to_s.length, new_len: kwargs[:new_text].to_s.length }
          when 'grep'
            { pattern: (kwargs[:pattern] || kwargs[:query] || kwargs.values.first).to_s,
              path:    kwargs[:path] || Dir.pwd }
          when 'glob'
            { pattern: (kwargs[:pattern] || kwargs.values.first).to_s }
          when 'web_fetch'
            { url: (kwargs[:url] || kwargs.values.first).to_s }
          else
            { args: kwargs.keys.join(',') }
          end
        end

        def dispatch_client_tool(ref, **kwargs)
          case ref
          when 'sh'
            cmd = kwargs[:command] || kwargs[:cmd] || kwargs.values.first.to_s
            output, status = ::Open3.capture2e(cmd, chdir: Dir.pwd)
            "exit=#{status.exitstatus}\n#{output}"
          when 'file_read'
            path = kwargs[:path] || kwargs[:file_path] || kwargs.values.first.to_s
            ::File.exist?(path) ? ::File.read(path, encoding: 'utf-8') : "File not found: #{path}"
          when 'file_write'
            path = kwargs[:path] || kwargs[:file_path]
            content = kwargs[:content] || kwargs[:contents]
            ::File.write(path, content)
            "Written #{content.to_s.bytesize} bytes to #{path}"
          when 'file_edit'
            path = kwargs[:path] || kwargs[:file_path]
            old_text = kwargs[:old_text] || kwargs[:search]
            new_text = kwargs[:new_text] || kwargs[:replace]
            content = ::File.read(path, encoding: 'utf-8')
            content.sub!(old_text, new_text)
            ::File.write(path, content)
            "Edited #{path}"
          when 'list_directory'
            path = ::File.expand_path(kwargs[:path] || kwargs[:dir] || Dir.pwd)
            Dir.entries(path).reject { |e| e.start_with?('.') }.sort.join("\n")
          when 'grep'
            pattern = kwargs[:pattern] || kwargs[:query] || kwargs.values.first.to_s
            path = kwargs[:path] || Dir.pwd
            output, = ::Open3.capture2e('grep', '-rn', '--include=*.rb', pattern, path)
            output.lines.first(50).join
          when 'glob'
            pattern = kwargs[:pattern] || kwargs.values.first.to_s
            Dir.glob(pattern).first(100).join("\n")
          when 'web_fetch'
            url = kwargs[:url] || kwargs.values.first.to_s
            require 'net/http'
            uri = URI(url)
            Net::HTTP.get(uri)
          else
            "Tool #{ref} is not executable server-side. Use a legion_ prefixed tool instead."
          end
        end

        def notify_tool_event(type, ref, **data)
          handler = Thread.current[:legion_tool_event_handler]
          return unless handler

          handler.call(
            type:         type,
            tool_call_id: Thread.current[:legion_current_tool_call_id],
            tool_name:    ref,
            **data
          )
        end
      end

      def self.registered(app) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/AbcSize,Metrics/MethodLength
        app.helpers do # rubocop:disable Metrics/BlockLength
          include Legion::Logging::Helper

          # Minimal fallback implementations of shared API helpers.
          # These are used when Legion::LLM::Routes is mounted on a bare Sinatra app.
          # When mounted via Legion::API (the normal path), Legion::API::Helpers and
          # Legion::API::Validators provide full implementations that take precedence.
          unless method_defined?(:parse_request_body)
            define_method(:parse_request_body) do
              raw = request.body.read
              return {} if raw.nil? || raw.empty?

              begin
                parsed = Legion::JSON.load(raw)
              rescue StandardError => e
                handle_exception(e, level: :debug, operation: 'llm.routes.parse_request_body')
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { code: 'invalid_json', message: 'request body is not valid JSON' } })
              end

              unless parsed.respond_to?(:transform_keys)
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { code:    'invalid_request_body',
                                                  message: 'request body must be a JSON object' } })
              end

              parsed.transform_keys(&:to_sym)
            end
          end

          unless method_defined?(:validate_required!)
            define_method(:validate_required!) do |body, *keys|
              missing = keys.select { |k| body[k].nil? || (body[k].respond_to?(:empty?) && body[k].empty?) }
              return if missing.empty?

              halt 400, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { code:    'missing_fields',
                                                message: "required: #{missing.join(', ')}" } })
            end
          end

          unless method_defined?(:json_response)
            define_method(:json_response) do |data, status_code: 200|
              content_type :json
              status status_code
              Legion::JSON.dump({ data: data })
            end
          end

          unless method_defined?(:json_error)
            define_method(:json_error) do |code, message, status_code: 400|
              content_type :json
              status status_code
              Legion::JSON.dump({ error: { code: code, message: message } })
            end
          end

          unless method_defined?(:require_llm!)
            define_method(:require_llm!) do
              return if defined?(Legion::LLM) &&
                        Legion::LLM.respond_to?(:started?) &&
                        Legion::LLM.started?

              halt 503, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { code:    'llm_unavailable',
                                                message: 'LLM subsystem is not available' } })
            end
          end

          unless method_defined?(:cache_available?)
            define_method(:cache_available?) do
              defined?(Legion::Cache) &&
                Legion::Cache.respond_to?(:connected?) &&
                Legion::Cache.connected?
            end
          end

          unless method_defined?(:gateway_available?)
            define_method(:gateway_available?) do
              defined?(Legion::Extensions::LLM::Gateway::Runners::Inference)
            end
          end

          unless method_defined?(:validate_tools!)
            define_method(:validate_tools!) do |tool_list|
              unless tool_list.is_a?(Array) && tool_list.all? { |t| t.respond_to?(:transform_keys) }
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { code:    'invalid_tools',
                                                  message: 'tools must be an array of objects' } })
              end

              invalid = tool_list.any? do |t|
                ts = t.transform_keys(&:to_sym)
                ts[:name].to_s.empty?
              end
              return unless invalid

              halt 400, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { code:    'invalid_tools',
                                                message: 'each tool must have a non-empty name' } })
            end
          end

          unless method_defined?(:validate_messages!)
            define_method(:validate_messages!) do |msg_list|
              valid = msg_list.all? do |m|
                next false unless m.respond_to?(:key?) && m.respond_to?(:[])

                role          = m[:role] || m['role']
                content_value = m[:content] || m['content']

                !role.to_s.empty? &&
                  (m.key?(:content) || m.key?('content')) &&
                  !content_value.nil? &&
                  !(content_value.respond_to?(:empty?) && content_value.empty?)
              end
              return if valid

              halt 400, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { code:    'invalid_messages',
                                                message: 'each message must be an object with non-empty role and content' } })
            end
          end

          define_method(:build_client_tool_class) do |tname, tdesc, tschema|
            tool_ref = tname
            klass = Class.new(RubyLLM::Tool) do
              include Legion::LLM::Routes::ClientToolMethods

              description tdesc
              define_method(:name) { tool_ref }

              define_method(:execute) do |**kwargs|
                summary = summarize_tool_args(tool_ref, kwargs)
                log_tool(:info, tool_ref, 'executing', **summary)
                t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
                result = dispatch_client_tool(tool_ref, **kwargs)
                ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
                log_tool(:info, tool_ref, 'completed', duration_ms: ms, result_size: result.to_s.bytesize)
                notify_tool_event(:tool_result, tool_ref, result: result.to_s[0, 4096])
                result
              rescue StandardError => e
                ms = begin
                  ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
                rescue StandardError
                  nil
                end
                log_tool(:error, tool_ref, 'failed', duration_ms: ms, error: e.message)
                notify_tool_event(:tool_error, tool_ref, error: e.message)
                if defined?(Legion::Logging) && Legion::Logging.respond_to?(:log_exception)
                  Legion::Logging.log_exception(e, payload_summary: "client tool #{tool_ref} failed", component_type: :api)
                end
                "Tool error: #{e.message}"
              end
            end
            klass.params(tschema) if tschema.is_a?(Hash) && tschema[:properties]
            klass
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: "llm.routes.build_client_tool_class.#{tname}")
            nil
          end

          define_method(:extract_tool_calls) do |pipeline_response|
            tools_data = pipeline_response.tools
            return [] unless tools_data.is_a?(Array) && !tools_data.empty?

            tools_data.map do |tc|
              {
                id:        tc.respond_to?(:id) ? tc.id : (tc[:id] || tc['id']),
                name:      tc.respond_to?(:name) ? tc.name : (tc[:name] || tc['name'] || tc.to_s),
                arguments: tc.respond_to?(:arguments) ? tc.arguments : (tc[:arguments] || tc['arguments'] || {})
              }
            end
          end

          define_method(:emit_sse_event) do |stream, event_name, payload|
            level = event_name == 'text-delta' ? :debug : :info
            log.send(level, "[sse][emit] event=#{event_name} keys=#{payload.is_a?(Hash) ? payload.keys.join(',') : 'n/a'}")
            stream << "event: #{event_name}\ndata: #{Legion::JSON.dump(payload)}\n\n"
          end

          define_method(:emit_timeline_tool_events) do |stream, pipeline_response|
            timeline = Array(pipeline_response.timeline)
            timeline.each do |event|
              key = event[:key].to_s
              detail = event[:detail]
              data = event[:data].is_a?(Hash) ? event[:data] : {}
              name = key.split(':', 3).last
              next if name.to_s.empty?

              if key.start_with?('tool:result:')
                event_name = data[:status].to_s == 'error' ? 'tool-error' : 'tool-result'
                emit_sse_event(stream, event_name, {
                                 toolCallId: data[:tool_call_id],
                                 toolName:   name,
                                 result:     data[:result] || detail,
                                 status:     data[:status],
                                 timestamp:  Time.now.utc.iso8601
                               })
              elsif key.start_with?('tool:execute:')
                emit_sse_event(stream, 'tool-progress', {
                                 toolCallId: data[:tool_call_id],
                                 toolName:   name,
                                 type:       'execution_complete',
                                 args:       data[:arguments] || {},
                                 source:     data[:source],
                                 status:     detail,
                                 timestamp:  Time.now.utc.iso8601
                               })
              end
            end
          end

          define_method(:token_value) do |tokens, key|
            return nil if tokens.nil?
            return tokens[key] || tokens[key.to_s] if tokens.is_a?(Hash)

            method_name = { input: :input_tokens, output: :output_tokens, total: :total_tokens }[key]
            return tokens.public_send(method_name) if method_name && tokens.respond_to?(method_name)

            nil
          end
        end

        register_chat(app)
        register_providers(app)
      end

      def self.register_chat(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        register_inference(app)

        app.post '/api/llm/chat' do # rubocop:disable Metrics/BlockLength
          log.debug "API: POST /api/llm/chat params=#{params.keys}"
          require_llm!

          body = parse_request_body
          validate_required!(body, :message)

          message = body[:message]

          if defined?(Legion::MCP::TierRouter)
            tier_result = Legion::MCP::TierRouter.route(
              intent:  message,
              params:  body.except(:message, :model, :provider, :request_id),
              context: {}
            )
            if tier_result[:tier]&.zero?
              log.info "API: LLM tier-0 response request_id=#{body[:request_id] || 'generated'} latency_ms=#{tier_result[:latency_ms]}"
              halt json_response({
                                   response:           tier_result[:response],
                                   tier:               0,
                                   latency_ms:         tier_result[:latency_ms],
                                   pattern_confidence: tier_result[:pattern_confidence]
                                 })
            end
          end

          request_id = body[:request_id] || SecureRandom.uuid
          model      = body[:model]
          provider   = body[:provider]

          if gateway_available?
            ingress_result = Legion::Ingress.run(
              payload:      { message: message, model: model, provider: provider,
                              request_id: request_id },
              runner_class: 'Legion::Extensions::LLM::Gateway::Runners::Inference',
              function:     'chat',
              source:       'api'
            )

            unless ingress_result[:success]
              log.error "[api/llm/chat] ingress failed: #{ingress_result}"
              err = ingress_result[:error] || ingress_result[:status]
              err_code    = err.respond_to?(:dig) ? (err[:code] || 'gateway_error') : err.to_s
              err_message = err.respond_to?(:dig) ? (err[:message] || err.to_s) : err.to_s
              halt json_error(err_code, err_message, status_code: 502)
            end

            result = ingress_result[:result]

            if result.nil?
              log.warn "[api/llm/chat] runner returned nil (status=#{ingress_result[:status]})"
              halt json_error('empty_result', 'Gateway runner returned no result', status_code: 502)
            end

            if result.is_a?(Hash) && result[:error]
              re = result[:error]
              re_code    = re.respond_to?(:dig) ? (re[:code] || 'gateway_error') : re.to_s
              re_message = re.respond_to?(:dig) ? (re[:message] || re.to_s) : re.to_s
              halt json_error(re_code, re_message, status_code: 502)
            end

            response_content = if result.respond_to?(:content)
                                 result.content
                               elsif result.is_a?(Hash)
                                 result[:response] || result[:content] || result.to_s
                               else
                                 result.to_s
                               end

            meta = { routed_via: 'gateway' }
            meta[:model] = result.model.to_s if result.respond_to?(:model)
            meta[:tokens_in] = result.input_tokens if result.respond_to?(:input_tokens)
            meta[:tokens_out] = result.output_tokens if result.respond_to?(:output_tokens)

            halt json_response({ response: response_content, meta: meta }, status_code: 201)
          end

          if cache_available? && env['HTTP_X_LEGION_SYNC'] != 'true'
            llm = Legion::LLM
            rc  = Legion::LLM::ResponseCache
            rc.init_request(request_id)

            Thread.new do
              session  = llm.chat_direct(model: model, provider: provider)
              response = session.ask(message)
              rc.complete(
                request_id,
                response: response.content,
                meta:     {
                  model:      session.model.to_s,
                  tokens_in:  response.respond_to?(:input_tokens) ? response.input_tokens : nil,
                  tokens_out: response.respond_to?(:output_tokens) ? response.output_tokens : nil
                }
              )
            rescue StandardError => e
              handle_exception(e, level: :error, operation: 'llm.routes.chat_async', request_id: request_id)
              rc.fail_request(request_id, code: 'llm_error', message: e.message)
            end

            log.info "API: LLM chat request #{request_id} queued async"
            json_response({ request_id: request_id, poll_key: "llm:#{request_id}:status" },
                          status_code: 202)
          else
            result = Legion::LLM.chat(message: message, model: model, provider: provider,
                                      caller: { source: 'api', path: request.path })
            if result.is_a?(Legion::LLM::Pipeline::Response)
              raw_msg  = result.message
              content  = raw_msg.is_a?(Hash) ? (raw_msg[:content] || raw_msg['content']) : raw_msg.to_s
              routing  = result.routing || {}
              resolved_model = routing[:model] || routing['model']
              tokens = result.tokens || {}
              log.info "API: LLM chat request #{request_id} completed sync model=#{resolved_model}"
              json_response(
                {
                  response: content,
                  meta:     {
                    model:      resolved_model.to_s,
                    tokens_in:  token_value(tokens, :input),
                    tokens_out: token_value(tokens, :output)
                  }
                },
                status_code: 201
              )
            else
              response = result
              log.info "API: LLM chat request #{request_id} completed sync"
              json_response(
                {
                  response: response.respond_to?(:content) ? response.content : response.to_s,
                  meta:     {
                    model:      response.respond_to?(:model_id) ? response.model_id.to_s : model.to_s,
                    tokens_in:  response.respond_to?(:input_tokens) ? response.input_tokens : nil,
                    tokens_out: response.respond_to?(:output_tokens) ? response.output_tokens : nil
                  }
                },
                status_code: 201
              )
            end
          end
        end
      end

      def self.register_inference(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        app.post '/api/llm/inference' do # rubocop:disable Metrics/BlockLength
          require_llm!
          body = parse_request_body
          validate_required!(body, :messages)

          messages        = body[:messages]
          raw_tools       = body[:tools]
          requested_tools = body[:requested_tools] || []
          model           = body[:model]
          provider        = body[:provider]
          caller_context  = body[:caller]
          conversation_id = body[:conversation_id]
          request_id      = body[:request_id] || SecureRandom.uuid

          unless messages.is_a?(Array)
            halt 400, { 'Content-Type' => 'application/json' },
                 Legion::JSON.dump({ error: { code: 'invalid_messages', message: 'messages must be an array' } })
          end

          validate_messages!(messages)

          unless raw_tools.nil? || raw_tools.is_a?(Array)
            halt 400, { 'Content-Type' => 'application/json' },
                 Legion::JSON.dump({ error: { code: 'invalid_tools', message: 'tools must be an array' } })
          end

          tools = raw_tools || []
          validate_tools!(tools) unless tools.empty?

          caller_identity = env['legion.tenant_id'] || 'api:inference'
          last_user = messages.select { |m| (m[:role] || m['role']).to_s == 'user' }.last
          prompt    = (last_user || {})[:content] || (last_user || {})['content'] || ''

          route_t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

          if defined?(Legion::Gaia) && Legion::Gaia.respond_to?(:started?) && Legion::Gaia.started? && prompt.to_s.length.positive?
            begin
              gaia_t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
              frame = Legion::Gaia::InputFrame.new(
                content:      prompt,
                channel_id:   :api,
                content_type: :text,
                auth_context: { identity: caller_identity },
                metadata:     { source_type: :human_direct, salience: 0.9 }
              )
              Legion::Gaia.ingest(frame)
              gaia_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - gaia_t0) * 1000).round
              log.warn("[inference][timing] gaia_ingest=#{gaia_ms}ms request_id=#{request_id}")
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'llm.routes.gaia_ingest', request_id: request_id)
            end
          end

          tool_declarations = tools.filter_map do |tool|
            ts = tool.respond_to?(:transform_keys) ? tool.transform_keys(&:to_sym) : tool
            build_client_tool_class(ts[:name].to_s, ts[:description].to_s, ts[:parameters] || ts[:input_schema])
          end

          log.unknown "[llm][api] inference tools client=#{tool_declarations.size}"

          streaming = body[:stream] == true && request.preferred_type.to_s.include?('text/event-stream')
          normalized_caller = caller_context.respond_to?(:transform_keys) ? caller_context.transform_keys(&:to_sym) : {}
          safe_caller_fields = normalized_caller.slice(:context, :session_id, :trace_id)
          server_caller_fields = {
            source:       'api',
            path:         request.path,
            requested_by: { identity: caller_identity, type: :user, credential: :api }
          }
          effective_caller = server_caller_fields.merge(safe_caller_fields)
          caller_summary = [effective_caller[:source], effective_caller[:path]].compact.join(':')
          log.info(
            "[llm][api] inference.accepted request_id=#{request_id} " \
            "conversation_id=#{conversation_id || 'none'} caller=#{caller_summary} " \
            "messages=#{messages.size} client_tools=#{tools.size} requested_tools=#{Array(requested_tools).size} " \
            "requested_provider=#{provider || 'auto'} requested_model=#{model || 'auto'} stream=#{streaming}"
          )

          require 'legion/llm/pipeline/request' unless defined?(Legion::LLM::Pipeline::Request)
          require 'legion/llm/pipeline/executor' unless defined?(Legion::LLM::Pipeline::Executor)

          pipeline_request = Legion::LLM::Pipeline::Request.build(
            id:              request_id,
            messages:        messages,
            system:          body[:system],
            routing:         { provider: provider, model: model },
            tools:           tool_declarations,
            caller:          effective_caller,
            conversation_id: conversation_id,
            metadata:        { requested_tools: requested_tools },
            stream:          streaming,
            cache:           { strategy: :default, cacheable: true }
          )

          setup_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - route_t0) * 1000).round
          log.warn("[inference][timing] pre_pipeline_setup=#{setup_ms}ms request_id=#{request_id}")

          executor = Legion::LLM::Pipeline::Executor.new(pipeline_request)

          if streaming
            content_type 'text/event-stream'
            headers 'Cache-Control'     => 'no-cache',
                    'Connection'        => 'keep-alive',
                    'X-Accel-Buffering' => 'no'

            # rubocop:disable Metrics/BlockLength
            stream do |out|
              full_text = +''

              executor.tool_event_handler = lambda { |event|
                log.info("[inference][tool-event] type=#{event[:type]} tool=#{event[:tool_name]} id=#{event[:tool_call_id]}")
                case event[:type]
                when :tool_call
                  emit_sse_event(out, 'tool-call', {
                                   toolCallId: event[:tool_call_id],
                                   toolName:   event[:tool_name],
                                   args:       event[:arguments],
                                   timestamp:  Time.now.utc.iso8601
                                 })
                when :tool_result
                  emit_sse_event(out, 'tool-result', {
                                   toolCallId: event[:tool_call_id],
                                   toolName:   event[:tool_name],
                                   result:     event[:result],
                                   timestamp:  Time.now.utc.iso8601
                                 })
                when :tool_error
                  emit_sse_event(out, 'tool-error', {
                                   toolCallId: event[:tool_call_id],
                                   toolName:   event[:tool_name],
                                   result:     event[:error],
                                   status:     'error',
                                   timestamp:  Time.now.utc.iso8601
                                 })
                end
              }

              pipeline_response = executor.call_stream do |chunk|
                text = chunk.respond_to?(:content) ? chunk.content.to_s : chunk.to_s
                next if text.empty?

                full_text << text
                emit_sse_event(out, 'text-delta', { delta: text })
              end

              emit_timeline_tool_events(out, pipeline_response)

              enrichments = pipeline_response.enrichments
              emit_sse_event(out, 'enrichment', enrichments) if enrichments.is_a?(Hash) && !enrichments.empty?

              routing = pipeline_response.routing || {}
              tokens = pipeline_response.tokens || {}
              emit_sse_event(out, 'done', {
                               request_id:      request_id,
                               content:         full_text,
                               model:           (routing[:model] || routing['model']).to_s,
                               input_tokens:    token_value(tokens, :input),
                               output_tokens:   token_value(tokens, :output),
                               tool_calls:      extract_tool_calls(pipeline_response),
                               conversation_id: pipeline_response.conversation_id
                             })

              log.info(
                "[llm][api] inference.completed request_id=#{request_id} " \
                "conversation_id=#{pipeline_response.conversation_id || conversation_id || 'none'} " \
                "provider=#{routing[:provider] || routing['provider'] || 'unknown'} " \
                "model=#{routing[:model] || routing['model'] || 'unknown'} " \
                "tool_calls=#{extract_tool_calls(pipeline_response).size} " \
                "tool_executions=#{Array(pipeline_response.timeline).count { |event| event[:key].to_s.start_with?('tool:execute:') }} " \
                "stop_reason=#{pipeline_response.stop&.dig(:reason) || 'unknown'} stream=true"
              )
            rescue StandardError => e
              handle_exception(e, level: :error, operation: 'llm.routes.inference_stream', request_id: request_id)
              emit_sse_event(out, 'error', { code: 'stream_error', message: e.message })
            end
            # rubocop:enable Metrics/BlockLength
          else
            exec_t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            pipeline_response = executor.call
            exec_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - exec_t0) * 1000).round
            log.warn("[inference][timing] executor_call=#{exec_ms}ms request_id=#{request_id}")
            raw_msg = pipeline_response.message
            content = raw_msg.is_a?(Hash) ? (raw_msg[:content] || raw_msg['content']) : raw_msg.to_s
            routing = pipeline_response.routing || {}
            tokens = pipeline_response.tokens || {}
            tool_calls = extract_tool_calls(pipeline_response)

            log.info(
              "[llm][api] inference.completed request_id=#{request_id} " \
              "conversation_id=#{pipeline_response.conversation_id || conversation_id || 'none'} " \
              "provider=#{routing[:provider] || routing['provider'] || 'unknown'} " \
              "model=#{routing[:model] || routing['model'] || 'unknown'} " \
              "tool_calls=#{tool_calls.size} " \
              "tool_executions=#{Array(pipeline_response.timeline).count { |event| event[:key].to_s.start_with?('tool:execute:') }} " \
              "stop_reason=#{pipeline_response.stop&.dig(:reason) || 'unknown'} stream=false"
            )

            json_response({
                            request_id:      request_id,
                            content:         content,
                            tool_calls:      tool_calls,
                            stop_reason:     pipeline_response.stop&.dig(:reason)&.to_s,
                            model:           (routing[:model] || routing['model']).to_s,
                            input_tokens:    token_value(tokens, :input),
                            output_tokens:   token_value(tokens, :output),
                            conversation_id: pipeline_response.conversation_id
                          }, status_code: 200)
          end
        rescue Legion::LLM::AuthError => e
          handle_exception(e, level: :error, operation: 'llm.routes.inference_auth', request_id: request_id)
          json_error('auth_error', e.message, status_code: 401)
        rescue Legion::LLM::RateLimitError => e
          handle_exception(e, level: :error, operation: 'llm.routes.inference_rate_limit', request_id: request_id)
          json_error('rate_limit', e.message, status_code: 429)
        rescue Legion::LLM::TokenBudgetExceeded => e
          handle_exception(e, level: :error, operation: 'llm.routes.inference_budget', request_id: request_id)
          json_error('token_budget_exceeded', e.message, status_code: 413)
        rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
          handle_exception(e, level: :error, operation: 'llm.routes.inference_provider', request_id: request_id)
          json_error('provider_error', e.message, status_code: 502)
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'llm.routes.inference', request_id: request_id)
          json_error('inference_error', e.message, status_code: 500)
        end
      end

      def self.register_providers(app)
        app.get '/api/llm/providers' do
          require_llm!
          unless gateway_available? && defined?(Legion::Extensions::LLM::Gateway::Runners::ProviderStats)
            halt json_error('gateway_unavailable', 'LLM gateway is not loaded', status_code: 503)
          end

          stats = Legion::Extensions::LLM::Gateway::Runners::ProviderStats
          json_response({
                          providers: stats.health_report,
                          summary:   stats.circuit_summary
                        })
        end

        app.get '/api/llm/providers/:name' do
          require_llm!
          unless gateway_available? && defined?(Legion::Extensions::LLM::Gateway::Runners::ProviderStats)
            halt json_error('gateway_unavailable', 'LLM gateway is not loaded', status_code: 503)
          end

          stats = Legion::Extensions::LLM::Gateway::Runners::ProviderStats
          detail = stats.provider_detail(provider: params[:name])
          json_response(detail)
        end
      end

      class << self
        private :register_chat, :register_inference, :register_providers
      end
    end
  end
end
