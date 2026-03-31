# frozen_string_literal: true

# Self-registering route module for legion-llm.
# All routes previously defined in LegionIO/lib/legion/api/llm.rb now live here
# and are mounted via Legion::API.register_library_routes when legion-llm boots.
#
# LegionIO/lib/legion/api/llm.rb is preserved for backward compatibility but guards
# its registration with defined?(Legion::LLM::Routes) so double-registration is avoided.

require 'securerandom'

module Legion
  module LLM
    module Routes
      def self.registered(app) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/AbcSize,Metrics/MethodLength
        app.helpers do # rubocop:disable Metrics/BlockLength
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
              rescue StandardError
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
        end

        register_chat(app)
        register_providers(app)
      end

      def self.register_chat(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        register_inference(app)

        app.post '/api/llm/chat' do # rubocop:disable Metrics/BlockLength
          Legion::Logging.debug "API: POST /api/llm/chat params=#{params.keys}" if defined?(Legion::Logging)
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
              Legion::Logging.error "[api/llm/chat] ingress failed: #{ingress_result}" if defined?(Legion::Logging)
              err = ingress_result[:error] || ingress_result[:status]
              err_code    = err.respond_to?(:dig) ? (err[:code] || 'gateway_error') : err.to_s
              err_message = err.respond_to?(:dig) ? (err[:message] || err.to_s) : err.to_s
              halt json_error(err_code, err_message, status_code: 502)
            end

            result = ingress_result[:result]

            if result.nil?
              Legion::Logging.warn "[api/llm/chat] runner returned nil (status=#{ingress_result[:status]})" if defined?(Legion::Logging)
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
              Legion::Logging.error "API POST /api/llm/chat async: #{e.class} — #{e.message}" if defined?(Legion::Logging)
              rc.fail_request(request_id, code: 'llm_error', message: e.message)
            end

            Legion::Logging.info "API: LLM chat request #{request_id} queued async" if defined?(Legion::Logging)
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
              Legion::Logging.info "API: LLM chat request #{request_id} completed sync model=#{resolved_model}" if defined?(Legion::Logging)
              json_response(
                {
                  response: content,
                  meta:     {
                    model:      resolved_model.to_s,
                    tokens_in:  tokens[:input],
                    tokens_out: tokens[:output]
                  }
                },
                status_code: 201
              )
            else
              response = result
              Legion::Logging.info "API: LLM chat request #{request_id} completed sync" if defined?(Legion::Logging)
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
          model           = body[:model]
          provider        = body[:provider]
          caller_context  = body[:caller]
          conversation_id = body[:conversation_id]

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

          tool_declarations = []
          unless tools.empty?
            validate_tools!(tools)

            tool_declarations = tools.map do |t|
              ts = t.respond_to?(:transform_keys) ? t.transform_keys(&:to_sym) : t
              tname   = ts[:name].to_s
              tdesc   = ts[:description].to_s
              tparams = ts[:parameters] || {}
              Class.new do
                define_singleton_method(:tool_name)   { tname }
                define_singleton_method(:description) { tdesc }
                define_singleton_method(:parameters)  { tparams }
                define_method(:call) { |**_| raise NotImplementedError, "#{tname} executes client-side only" }
              end
            end
          end

          normalized_messages = messages.map do |m|
            ms = m.respond_to?(:transform_keys) ? m.transform_keys(&:to_sym) : m
            { role: ms[:role].to_s, content: ms[:content].to_s }
          end

          effective_caller = caller_context || { source: 'api', path: request.path }
          chat_opts = {
            messages: normalized_messages,
            model:    model,
            provider: provider,
            tools:    tool_declarations,
            caller:   effective_caller
          }
          chat_opts[:conversation_id] = conversation_id if conversation_id

          result = Legion::LLM.chat(**chat_opts)

          if result.is_a?(Legion::LLM::Pipeline::Response)
            raw_msg   = result.message
            content   = raw_msg.is_a?(Hash) ? (raw_msg[:content] || raw_msg['content']) : raw_msg.to_s
            routing   = result.routing || {}
            resolved_model = routing[:model] || routing['model']
            tokens = result.tokens || {}
            json_response({
                            content:       content,
                            tool_calls:    nil,
                            stop_reason:   result.stop&.dig(:reason)&.to_s,
                            model:         resolved_model.to_s,
                            input_tokens:  tokens[:input],
                            output_tokens: tokens[:output]
                          }, status_code: 200)
          else
            response = result
            tc_list = if response.respond_to?(:tool_calls) && response.tool_calls
                        Array(response.tool_calls).map do |tc|
                          {
                            id:        tc.respond_to?(:id) ? tc.id : nil,
                            name:      tc.respond_to?(:name) ? tc.name : tc.to_s,
                            arguments: tc.respond_to?(:arguments) ? tc.arguments : {}
                          }
                        end
                      end
            json_response({
                            content:       response.respond_to?(:content) ? response.content : response.to_s,
                            tool_calls:    tc_list,
                            stop_reason:   response.respond_to?(:stop_reason) ? response.stop_reason : nil,
                            model:         response.respond_to?(:model_id) ? response.model_id.to_s : model.to_s,
                            input_tokens:  response.respond_to?(:input_tokens) ? response.input_tokens : nil,
                            output_tokens: response.respond_to?(:output_tokens) ? response.output_tokens : nil
                          }, status_code: 200)
          end
        rescue StandardError => e
          Legion::Logging.error "[api/llm/inference] #{e.class}: #{e.message}" if defined?(Legion::Logging)
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
