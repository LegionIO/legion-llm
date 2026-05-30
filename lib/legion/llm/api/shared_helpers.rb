# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/types'
require_relative '../publisher_identity'
require 'legion/llm/api/translators/openai_response'

begin
  require 'legion/identity/request'
  require 'legion/identity/process'
rescue LoadError => e
  Object.new.extend(Legion::Logging::Helper).handle_exception(
    e, level: :debug, handled: true, operation: 'llm.api.shared_helpers.optional_identity_require'
  )
end

module Legion
  module LLM
    module API
      module SharedHelpers
        include Legion::Logging::Helper

        # ---------------------------------------------------------------------------
        # Request parsing
        # ---------------------------------------------------------------------------

        def parse_request_body
          log.debug('[llm][api][shared_helpers] parse_request_body action=parsing')
          raw = request.body.read
          return {} if raw.nil? || raw.empty?

          parsed = begin
            Legion::JSON.load(raw)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.api.parse_request_body')
            halt 400, { 'Content-Type' => 'application/json' },
                 Legion::JSON.dump({ error: { code: 'invalid_json', message: 'request body is not valid JSON' } })
          end

          unless parsed.respond_to?(:transform_keys)
            halt 400, { 'Content-Type' => 'application/json' },
                 Legion::JSON.dump({ error: { code: 'invalid_request_body', message: 'request body must be a JSON object' } })
          end

          parsed
        end

        # ---------------------------------------------------------------------------
        # Guards
        # ---------------------------------------------------------------------------

        def require_llm!
          return if Legion::LLM.started?

          log.debug('[llm][api][shared_helpers] require_llm! action=halting reason=not_started')
          halt 503, { 'Content-Type' => 'application/json' },
               Legion::JSON.dump({ error: { code: 'llm_unavailable', message: 'LLM subsystem is not available' } })
        end

        def validate_required!(body, *keys)
          missing = keys.select { |k| body[k].nil? || (body[k].respond_to?(:empty?) && body[k].empty?) }
          return if missing.empty?

          log.debug("[llm][api][shared_helpers] validate_required! missing=#{missing.join(',')}")
          halt 400, { 'Content-Type' => 'application/json' },
               Legion::JSON.dump({ error: { code: 'missing_fields', message: "required: #{missing.join(', ')}" } })
        end

        def validate_messages!(msg_list)
          valid = msg_list.all? do |m|
            next false unless m.respond_to?(:key?) && m.respond_to?(:[])

            role = m[:role] || m['role']
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

        def validate_tools!(tool_list)
          unless tool_list.is_a?(Array) && tool_list.all? { |t| t.respond_to?(:transform_keys) }
            halt 400, { 'Content-Type' => 'application/json' },
                 Legion::JSON.dump({ error: { code: 'invalid_tools', message: 'tools must be an array of objects' } })
          end

          invalid = tool_list.any? do |t|
            ts = t.transform_keys(&:to_sym)
            ts[:name].to_s.empty?
          end
          return unless invalid

          halt 400, { 'Content-Type' => 'application/json' },
               Legion::JSON.dump({ error: { code: 'invalid_tools', message: 'each tool must have a non-empty name' } })
        end

        def cache_available?
          cache_connected? || local_cache_connected?
        end

        # ---------------------------------------------------------------------------
        # Responses
        # ---------------------------------------------------------------------------

        def json_response(data, status_code: 200)
          content_type :json
          status status_code
          Legion::JSON.dump({ data: data })
        end

        def json_error(code, message, status_code: 400)
          content_type :json
          status status_code
          Legion::JSON.dump({ error: { code: code, message: message } })
        end

        # Emit an SSE event to a streaming response body.
        # Logs every event type except 'text-delta' at info (preserving existing behavior
        # from api/native/helpers.rb: text-delta goes to debug, everything else to info).
        def emit_sse_event(stream, event_name, payload)
          level = event_name == 'text-delta' ? :debug : :info
          log.send(level, "[sse][emit] event=#{event_name} keys=#{payload.is_a?(Hash) ? payload.keys.join(',') : 'n/a'}")
          stream << "event: #{event_name}\ndata: #{Legion::JSON.dump(payload)}\n\n"
        end

        def log_native_inference_response(request_id:, conversation_id:, stream:, kind:, payload:)
          log.debug(
            "[llm][api][inference] action=response_payload request_id=#{request_id || 'unknown'} " \
            "conversation_id=#{conversation_id || 'none'} stream=#{stream} kind=#{kind} " \
            "payload=#{Legion::JSON.dump(payload)}"
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true,
                          operation: 'llm.api.inference.response_payload_log',
                          request_id: request_id)
        end

        def build_response_metrics(pipeline_response)
          routing = pipeline_response.routing || {}
          timestamps = pipeline_response.timestamps || {}
          metrics = {}

          if (latency = routing[:latency_ms])
            metrics[:latency_ms] = latency
          end

          step_timings = timestamps[:step_timings]
          if step_timings.is_a?(Hash) && step_timings.any?
            metrics[:timing] = step_timings
            total = step_timings[:total].to_i
            external = step_timings[:provider_call].to_i + step_timings[:tool_calls].to_i
            metrics[:latency_legionio_ms] = total - external if total.positive?
          end

          metrics.empty? ? nil : metrics
        end

        # ---------------------------------------------------------------------------
        # Tool helpers
        # ---------------------------------------------------------------------------

        def build_tool_definitions(tool_specs, executable: true)
          return [] if tool_specs.nil? || !tool_specs.is_a?(Array)

          tool_specs.filter_map do |spec|
            s = spec.respond_to?(:transform_keys) ? spec.transform_keys(&:to_sym) : spec
            next if s[:name].to_s.empty?

            Legion::LLM::Types::ToolDefinition.build(
              name:        s[:name].to_s,
              description: (s[:description] || '').to_s,
              parameters:  s[:parameters] || s[:input_schema] || {},
              source:      { type: :client, executable: executable }
            )
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: "llm.api.build_tool.#{s[:name]}")
            nil
          end
        end

        def build_client_tool_class(tname, tdesc, tschema)
          log.debug("[llm][api][shared_helpers] build_client_tool_class name=#{tname}")
          Legion::LLM::Types::ToolDefinition.build(
            name:        tname,
            description: tdesc,
            parameters:  tschema || {},
            source:      { type: :client, executable: false, raw_name: tname }
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: "llm.api.build_client_tool_class.#{tname}")
          nil
        end

        def extract_tool_calls(pipeline_response)
          Legion::LLM::API::Translators::OpenAIResponse.build_tool_calls(pipeline_response)
        end

        def openai_tool_call_name(tool_call)
          fn = tool_call[:function] || tool_call['function'] || {}
          fn[:name] || fn['name'] || tool_call[:name] || tool_call['name']
        end

        def openai_tool_call_arguments(tool_call)
          fn = tool_call[:function] || tool_call['function'] || {}
          raw_args = fn[:arguments] || fn['arguments'] || tool_call[:arguments] || tool_call['arguments'] || {}
          return raw_args unless raw_args.is_a?(String)

          Legion::JSON.parse(raw_args, symbolize_names: true)
        rescue StandardError
          raw_args
        end

        def returned_client_tool_call_payload(tool_call, tool_call_id, tool_name)
          {
            toolCallId:         tool_call_id,
            toolName:           tool_name,
            args:               openai_tool_call_arguments(tool_call),
            clientPassthrough:  true,
            requiresToolResult: true,
            status:             'requires_client_execution',
            timestamp:          Time.now.utc.iso8601
          }
        end

        def emit_response_tool_call_events(_stream, pipeline_response)
          tool_calls = extract_tool_calls(pipeline_response)
          return if tool_calls.empty?

          timeline_tool_call_ids = Array(pipeline_response.timeline).filter_map do |event|
            key = event[:key].to_s
            next unless key.start_with?('tool:execute:')

            data = event[:data].is_a?(Hash) ? event[:data] : {}
            data[:tool_call_id] || data['tool_call_id']
          end

          done_only = 0
          skipped_timeline = 0
          request_id = pipeline_response.respond_to?(:request_id) ? pipeline_response.request_id : 'unknown'
          conversation_id = pipeline_response.respond_to?(:conversation_id) ? pipeline_response.conversation_id : 'none'

          tool_calls.each do |tool_call|
            tool_call_id = tool_call[:id] || tool_call['id']
            if tool_call_id && timeline_tool_call_ids.include?(tool_call_id)
              skipped_timeline += 1
              next
            end

            tool_name = openai_tool_call_name(tool_call)
            next if tool_name.to_s.empty?

            log.info(
              "[llm][api][tools] action=returned_tool_call_done_only request_id=#{request_id} " \
              "conversation_id=#{conversation_id} tool_call_id=#{tool_call_id || 'none'} name=#{tool_name} " \
              "args_class=#{openai_tool_call_arguments(tool_call).class}"
            )
            done_only += 1
          end

          names = tool_calls.map { |tc| openai_tool_call_name(tc) }.compact
          names_str = names.first(30).join(',') + (names.size > 30 ? ",+#{names.size - 30}more" : '')
          log.info(
            "[llm][api][tools] action=returned_tool_calls_complete request_id=#{request_id} " \
            "conversation_id=#{conversation_id} total=#{tool_calls.size} done_only=#{done_only} " \
            "skipped_timeline=#{skipped_timeline} names=#{names_str.empty? ? 'none' : names_str}"
          )
        end

        def emit_timeline_tool_events(stream, pipeline_response, skip_tool_results: false)
          timeline = Array(pipeline_response.timeline)
          log.debug("[llm][api][shared_helpers] emit_timeline_tool_events count=#{timeline.size} skip_tool_results=#{skip_tool_results}")
          timeline.each do |event|
            key = event[:key].to_s
            detail = event[:detail]
            data = event[:data].is_a?(Hash) ? event[:data] : {}
            name = key.split(':', 3).last
            next if name.to_s.empty?

            if key.start_with?('tool:result:')
              next if skip_tool_results

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

        # ---------------------------------------------------------------------------
        # Content extraction
        # ---------------------------------------------------------------------------

        def extract_text_content(content)
          case content
          when nil then ''
          when String then content
          when Array then content.filter_map { |entry| extract_text_content(entry) }.join
          when Hash
            type = content[:type] || content['type']
            return '' unless type.nil? || type.to_s == 'text'

            # Explicit parens to avoid operator precedence ambiguity between || and ?:
            text = content.key?(:text) || content.key?('text') ? (content[:text] || content['text']) : (content[:content] || content['content'])
            extract_text_content(text)
          else
            content.respond_to?(:text) ? content.text.to_s : content.to_s
          end
        end

        def token_value(tokens, key)
          return nil if tokens.nil?
          return tokens[key] || tokens[key.to_s] if tokens.is_a?(Hash)

          method_name = { input: :input_tokens, output: :output_tokens, total: :total_tokens }[key]
          return tokens.public_send(method_name) if method_name && tokens.respond_to?(method_name)

          nil
        end

        # ---------------------------------------------------------------------------
        # Identity resolution chain
        # ---------------------------------------------------------------------------

        def identity_request_from_env(rack_env)
          return nil unless defined?(Legion::Identity::Request)
          return nil unless Legion::Identity::Request.respond_to?(:from_env)

          Legion::Identity::Request.from_env(rack_env)
        end

        def identity_canonical_name(rack_env)
          request_identity = identity_request_from_env(rack_env)
          if request_identity.respond_to?(:to_caller_hash)
            caller_hash = request_identity.to_caller_hash
            if caller_hash.is_a?(Hash)
              requested_by = caller_hash[:requested_by] || caller_hash['requested_by']
              unless Legion::LLM::PublisherIdentity.generic_requested_by?(requested_by)
                name = requested_by[:identity] || requested_by['identity'] if requested_by.respond_to?(:key?)
                return name if name && name.to_s != ''
              end
            end
          end

          publisher_identity = Legion::LLM::PublisherIdentity.requested_by[:identity]
          return publisher_identity if publisher_identity && publisher_identity.to_s != ''

          if defined?(Legion::Identity::Process) && Legion::Identity::Process.respond_to?(:canonical_name)
            process_name = Legion::Identity::Process.canonical_name
            return process_name if process_name && process_name.to_s != ''
          end

          raw = ENV.fetch('USER', nil) || ENV.fetch('LOGNAME', nil) || 'anonymous'
          raw.to_s.include?('@') ? raw.to_s.split('@').first : raw.to_s
        end

        def identity_caller_hash(rack_env)
          request_identity = identity_request_from_env(rack_env)
          if request_identity.respond_to?(:to_caller_hash)
            caller_hash = request_identity.to_caller_hash
            if caller_hash.is_a?(Hash)
              requested_by = caller_hash[:requested_by] || caller_hash['requested_by']
              return { requested_by: requested_by } if requested_by && !Legion::LLM::PublisherIdentity.generic_requested_by?(requested_by)
            end
          end

          { requested_by: Legion::LLM::PublisherIdentity.requested_by }
        end

        def build_server_caller(source:, path:, env:, caller_context: nil)
          normalized_caller = caller_context.respond_to?(:transform_keys) ? caller_context.transform_keys(&:to_sym) : {}
          safe_caller_fields = normalized_caller.slice(:context, :session_id, :trace_id)

          {
            source:       source,
            path:         path,
            requested_by: identity_caller_hash(env).fetch(:requested_by)
          }.merge(safe_caller_fields)
        end

        def detect_modality(messages)
          return nil unless messages.is_a?(Array)

          messages.each do |msg|
            content = msg[:content] || msg['content']
            next unless content.is_a?(Array)

            content.each do |block|
              b = block.is_a?(Hash) ? block : next
              type = (b[:type] || b['type']).to_s
              return :vision if %w[image image_url].include?(type)
              return :vision if b[:source] && (b.dig(:source, :type) || b.dig(:source, 'type')).to_s == 'base64'
            end
          end

          nil
        end
      end
    end
  end
end
