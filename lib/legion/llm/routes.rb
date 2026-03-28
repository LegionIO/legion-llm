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

              Legion::JSON.load(raw).transform_keys(&:to_sym)
            rescue StandardError
              halt 400, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { code: 'invalid_json', message: 'request body is not valid JSON' } })
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

          define_method(:require_llm!) do
            return if defined?(Legion::LLM) &&
                      Legion::LLM.respond_to?(:started?) &&
                      Legion::LLM.started?

            halt 503, { 'Content-Type' => 'application/json' },
                 Legion::JSON.dump({ error: { code:    'llm_unavailable',
                                              message: 'LLM subsystem is not available' } })
          end

          define_method(:cache_available?) do
            defined?(Legion::Cache) &&
              Legion::Cache.respond_to?(:connected?) &&
              Legion::Cache.connected?
          end

          define_method(:gateway_available?) do
            defined?(Legion::Extensions::LLM::Gateway::Runners::Inference)
          end

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

          define_method(:validate_messages!) do |msg_list|
            valid = msg_list.all? do |m|
              m.respond_to?(:key?) &&
                !(m[:role] || m['role']).to_s.empty? &&
                (m.key?(:content) || m.key?('content'))
            end
            return if valid

            halt 400, { 'Content-Type' => 'application/json' },
                 Legion::JSON.dump({ error: { code:    'invalid_messages',
                                              message: 'each message must be an object with non-empty role and content' } })
          end
        end

        register_chat(app)
        register_providers(app)
      end

      def self.register_chat(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        register_inference(app)

        app.post '/api/llm/chat' do # rubocop:disable Metrics/BlockLength
          Legion::Logging.debug "API: POST /api/llm/chat params=#{params.keys}"
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
              Legion::Logging.error "[api/llm/chat] ingress failed: #{ingress_result}"
              halt json_response({ error: ingress_result[:error] || ingress_result[:status] },
                                 status_code: 502)
            end

            result = ingress_result[:result]

            if result.nil?
              Legion::Logging.warn "[api/llm/chat] runner returned nil (status=#{ingress_result[:status]})"
              halt json_response({ error: { code:    'empty_result',
                                            message: 'Gateway runner returned no result' } },
                                 status_code: 502)
            end

            halt json_response({ error: result[:error] }, status_code: 502) if result.is_a?(Hash) && result[:error]

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
              Legion::Logging.error "API POST /api/llm/chat async: #{e.class} — #{e.message}"
              rc.fail_request(request_id, code: 'llm_error', message: e.message)
            end

            Legion::Logging.info "API: LLM chat request #{request_id} queued async"
            json_response({ request_id: request_id, poll_key: "llm:#{request_id}:status" },
                          status_code: 202)
          else
            session  = Legion::LLM.chat(model: model, provider: provider,
                                        caller: { source: 'api', path: request.path })
            response = session.ask(message)
            Legion::Logging.info "API: LLM chat request #{request_id} completed sync model=#{session.model}"
            json_response(
              {
                response: response.content,
                meta:     {
                  model:      session.model.to_s,
                  tokens_in:  response.respond_to?(:input_tokens) ? response.input_tokens : nil,
                  tokens_out: response.respond_to?(:output_tokens) ? response.output_tokens : nil
                }
              },
              status_code: 201
            )
          end
        end
      end

      def self.register_inference(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        app.post '/api/llm/inference' do # rubocop:disable Metrics/BlockLength
          require_llm!
          body = parse_request_body
          validate_required!(body, :messages)

          messages = body[:messages]
          raw_tools = body[:tools]
          model    = body[:model]
          provider = body[:provider]

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

          session = Legion::LLM.chat(
            model:    model,
            provider: provider,
            caller:   { source: 'api', path: request.path }
          )

          unless tools.empty?
            validate_tools!(tools)

            tool_declarations = tools.map do |t|
              ts = t.respond_to?(:transform_keys) ? t.transform_keys(&:to_sym) : t
              tname  = ts[:name].to_s
              tdesc  = ts[:description].to_s
              tparams = ts[:parameters] || {}
              Class.new do
                define_singleton_method(:tool_name)   { tname }
                define_singleton_method(:description) { tdesc }
                define_singleton_method(:parameters)  { tparams }
                define_method(:call) { |**_| raise NotImplementedError, "#{tname} executes client-side only" }
              end
            end
            session.with_tools(*tool_declarations)
          end

          last_user      = messages.select { |m| (m[:role] || m['role']).to_s == 'user' }.last
          prior_messages = last_user ? (messages - [last_user]) : messages
          prior_messages.each { |m| session.add_message(m) }

          prompt   = (last_user || {})[:content] || (last_user || {})['content'] || ''
          response = session.ask(prompt)

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
                          content:       response.content,
                          tool_calls:    tc_list,
                          stop_reason:   response.respond_to?(:stop_reason) ? response.stop_reason : nil,
                          model:         session.model.to_s,
                          input_tokens:  response.respond_to?(:input_tokens) ? response.input_tokens : nil,
                          output_tokens: response.respond_to?(:output_tokens) ? response.output_tokens : nil
                        }, status_code: 200)
        rescue StandardError => e
          Legion::Logging.error "[api/llm/inference] #{e.class}: #{e.message}" if defined?(Legion::Logging)
          json_response({ error: { code: 'inference_error', message: e.message } }, status_code: 500)
        end
      end

      def self.register_providers(app)
        app.get '/api/llm/providers' do
          require_llm!
          unless gateway_available? && defined?(Legion::Extensions::LLM::Gateway::Runners::ProviderStats)
            halt 503, json_error('gateway_unavailable', 'LLM gateway is not loaded', status_code: 503)
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
            halt 503, json_error('gateway_unavailable', 'LLM gateway is not loaded', status_code: 503)
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
