# frozen_string_literal: true

require 'securerandom'
require 'open3'
require 'time'
require 'legion/cache/helper'
require 'legion/logging/helper'
require 'legion/llm/api/translators/openai_response'
require 'legion/llm/publisher_identity'
require 'legion/llm/types'

begin
  require 'legion/identity/request'
  require 'legion/identity/process'
rescue LoadError => e
  Object.new.extend(Legion::Logging::Helper).handle_exception(
    e, level: :debug, handled: true, operation: 'llm.api.native.helpers.optional_identity_require'
  )
end

module Legion
  module LLM
    module API
      module Native
        module ClientToolMethods
          include Legion::Logging::Helper

          private

          def log_tool(level, ref, status, **details)
            parts = ["[tool][#{ref}] #{status}"]
            details.each { |k, v| parts << "#{k}=#{v}" }
            log.public_send(level, parts.join(' '))
          end

          def summarize_tool_arg_keys(kwargs)
            kwargs.keys.map(&:to_s).sort.join(',')
          end

          def summarize_tool_args(ref, kwargs)
            case ref
            when 'sh'
              { args: summarize_tool_arg_keys(kwargs), command_provided: kwargs.key?(:command) || kwargs.key?(:cmd) || !kwargs.empty? }
            when 'file_write'
              content = kwargs[:content] || kwargs[:contents]
              { args: summarize_tool_arg_keys(kwargs), bytes: content.to_s.bytesize }
            when 'file_edit'
              { args: summarize_tool_arg_keys(kwargs),
                old_len: kwargs[:old_text].to_s.length, new_len: kwargs[:new_text].to_s.length }
            else
              { args: summarize_tool_arg_keys(kwargs) }
            end
          end

          def dispatch_client_tool(ref, **kwargs) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
            case ref
            when 'sh'
              cmd = kwargs[:command] || kwargs[:cmd] || kwargs.values.first.to_s
              output, status = ::Open3.capture2e(cmd, chdir: Dir.pwd)
              "exit=#{status.exitstatus}\n#{output}"
            when 'file_read'
              path = kwargs[:path] || kwargs[:file_path] || kwargs.values.first.to_s
              read_client_file(path)
            when 'file_write'
              path = kwargs[:path] || kwargs[:file_path]
              content = kwargs[:content] || kwargs[:contents]
              ::File.write(path, content)
              "Written #{content.to_s.bytesize} bytes to #{path}"
            when 'file_edit'
              path = kwargs[:path] || kwargs[:file_path]
              old_text = kwargs[:old_text] || kwargs[:search]
              new_text = kwargs[:new_text] || kwargs[:replace]
              return 'file_edit error: old_text is required' if old_text.nil? || old_text.empty?

              content = ::File.read(path, encoding: 'utf-8')
              content.sub!(old_text, new_text || '')
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
              raw_max_length = kwargs[:maxLength] || kwargs[:max_length]
              max_length = raw_max_length.nil? ? nil : [raw_max_length.to_i, 0].max
              begin
                require 'legion/cli/chat/web_fetch'
                content = Legion::CLI::Chat::WebFetch.fetch(url)
                max_length ? content[0, max_length] : content
              rescue LoadError => e
                missing = e.respond_to?(:path) && e.path ? e.path : 'legion/cli/chat/web_fetch'
                handle_exception(e, level: :warn, handled: true, operation: 'llm.api.client_tool.web_fetch', missing: missing)
                "web_fetch is unavailable: missing optional dependency #{missing}"
              end
            when 'web_search'
              query = kwargs[:query] || kwargs.values.first.to_s
              max_results = (kwargs[:max_results] || kwargs[:maxResults] || 5).to_i
              begin
                require 'legion/cli/chat/web_search'
                results = Legion::CLI::Chat::WebSearch.search(query, max_results: max_results, auto_fetch: false)
                results[:results].map { |r| "### #{r[:title]}\n#{r[:url]}\n#{r[:snippet]}" }.join("\n\n")
              rescue LoadError => e
                missing = e.respond_to?(:path) && e.path ? e.path : 'legion/cli/chat/web_search'
                handle_exception(e, level: :warn, handled: true, operation: 'llm.api.client_tool.web_search', missing: missing)
                "web_search is unavailable: missing optional dependency #{missing}"
              end
            else
              "Tool #{ref} is not executable server-side. Use a legion_ prefixed tool instead."
            end
          end

          def read_client_file(path)
            return "File not found: #{path}" unless ::File.exist?(path)

            return read_pdf_text(path) if pdf_file?(path)

            content = ::File.binread(path)
            return 'Binary file detected, cannot read as text.' if binary_content?(content)

            content.force_encoding('UTF-8')
            content
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.api.client_tool.file_read', path: path)
            "file_read error: #{e.message}"
          end

          def pdf_file?(path)
            ::File.extname(path).casecmp('.pdf').zero? || ::File.binread(path, 5) == '%PDF-'
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.api.client_tool.pdf_sniff', path: path)
            false
          end

          def read_pdf_text(path)
            require 'pdf-reader' unless defined?(::PDF::Reader)

            reader = ::PDF::Reader.new(path)
            text = reader.pages.map(&:text).join("\n\n").strip
            text.empty? ? 'PDF contained no extractable text.' : text
          rescue LoadError => e
            missing = e.respond_to?(:path) && e.path ? e.path : 'pdf-reader'
            handle_exception(e, level: :warn, handled: true, operation: 'llm.api.client_tool.pdf_extract', missing: missing)
            'PDF text extraction unavailable: missing pdf-reader gem.'
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.api.client_tool.pdf_extract', path: path)
            "PDF text extraction failed: #{e.message}"
          end

          def binary_content?(content)
            return true if content.include?("\x00")

            sample = content.byteslice(0, 4096).to_s
            sample.force_encoding('UTF-8')
            !sample.valid_encoding?
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

        module Helpers
          extend Legion::Logging::Helper

          def self.registered(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
            log.debug('[llm][api][helpers] registering shared helpers')

            app.helpers do # rubocop:disable Metrics/BlockLength
              include Legion::Logging::Helper
              include ::Legion::Cache::Helper

              unless method_defined?(:parse_request_body)
                define_method(:parse_request_body) do
                  log.debug('[llm][api][helpers] parse_request_body action=parsing')
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

                  log.debug("[llm][api][helpers] validate_required! missing=#{missing.join(',')}")
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

                  log.debug('[llm][api][helpers] require_llm! action=halting reason=not_started')
                  halt 503, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { code:    'llm_unavailable',
                                                    message: 'LLM subsystem is not available' } })
                end
              end

              unless method_defined?(:cache_available?)
                define_method(:cache_available?) do
                  cache_connected? || local_cache_connected?
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
                log.debug("[llm][api][helpers] build_client_tool_class name=#{tname}")
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

              define_method(:extract_tool_calls) do |pipeline_response|
                Legion::LLM::API::Translators::OpenAIResponse.build_tool_calls(pipeline_response)
              end

              define_method(:extract_text_content) do |content|
                case content
                when nil
                  ''
                when String
                  content
                when Array
                  content.filter_map { |entry| extract_text_content(entry) }.join
                when Hash
                  type = content[:type] || content['type']
                  return '' unless type.nil? || type.to_s == 'text'

                  text = content.key?(:text) || content.key?('text') ? (content[:text] || content['text']) : (content[:content] || content['content'])
                  extract_text_content(text)
                else
                  content.respond_to?(:text) ? content.text.to_s : content.to_s
                end
              end

              define_method(:emit_sse_event) do |stream, event_name, payload|
                level = event_name == 'text-delta' ? :debug : :info
                log.send(level, "[sse][emit] event=#{event_name} keys=#{payload.is_a?(Hash) ? payload.keys.join(',') : 'n/a'}")
                stream << "event: #{event_name}\ndata: #{Legion::JSON.dump(payload)}\n\n"
              end

              define_method(:log_native_inference_response) do |request_id:, conversation_id:, stream:, kind:, payload:|
                log.debug(
                  "[llm][api][inference] action=response_payload request_id=#{request_id || 'unknown'} " \
                  "conversation_id=#{conversation_id || 'none'} stream=#{stream} kind=#{kind} " \
                  "payload=#{Legion::JSON.dump(payload)}"
                )
              rescue StandardError => e
                handle_exception(e, level: :debug, handled: true,
                                    operation: 'llm.api.inference.response_payload_log',
                                    request_id: request_id)
              end

              define_method(:returned_client_tool_call_payload) do |tool_call, tool_call_id, tool_name|
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

              define_method(:openai_tool_call_name) do |tool_call|
                fn = tool_call[:function] || tool_call['function'] || {}
                fn[:name] || fn['name'] || tool_call[:name] || tool_call['name']
              end

              define_method(:openai_tool_call_arguments) do |tool_call|
                fn = tool_call[:function] || tool_call['function'] || {}
                raw_args = fn[:arguments] || fn['arguments'] || tool_call[:arguments] || tool_call['arguments'] || {}
                return raw_args unless raw_args.is_a?(String)

                Legion::JSON.parse(raw_args, symbolize_names: true)
              rescue StandardError
                raw_args
              end

              define_method(:emit_response_tool_call_events) do |_stream, pipeline_response|
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
                    "[llm][api][tools] action=returned_tool_call_done_only request_id=#{request_id || 'unknown'} " \
                    "conversation_id=#{conversation_id || 'none'} tool_call_id=#{tool_call_id || 'none'} name=#{tool_name} " \
                    "args_class=#{openai_tool_call_arguments(tool_call).class}"
                  )
                  done_only += 1
                end

                names = tool_calls.map { |tool_call| openai_tool_call_name(tool_call) }.compact
                names = names.first(30).join(',') + (names.size > 30 ? ",+#{names.size - 30}more" : '')
                log.info(
                  "[llm][api][tools] action=returned_tool_calls_complete request_id=#{request_id || 'unknown'} " \
                  "conversation_id=#{conversation_id || 'none'} total=#{tool_calls.size} done_only=#{done_only} " \
                  "skipped_timeline=#{skipped_timeline} names=#{names.empty? ? 'none' : names}"
                )
              end

              define_method(:emit_timeline_tool_events) do |stream, pipeline_response, skip_tool_results: false|
                timeline = Array(pipeline_response.timeline)
                log.debug("[llm][api][helpers] emit_timeline_tool_events count=#{timeline.size} skip_tool_results=#{skip_tool_results}")
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

              define_method(:identity_request_from_env) do |rack_env|
                return nil unless defined?(Legion::Identity::Request)
                return nil unless Legion::Identity::Request.respond_to?(:from_env)

                Legion::Identity::Request.from_env(rack_env)
              end

              define_method(:identity_canonical_name) do |rack_env|
                request_identity = identity_request_from_env(rack_env)
                if request_identity.respond_to?(:to_caller_hash)
                  caller_hash = request_identity.to_caller_hash
                  requested_by = nil
                  requested_by = caller_hash[:requested_by] || caller_hash['requested_by'] if caller_hash.is_a?(Hash)
                  unless Legion::LLM::PublisherIdentity.generic_requested_by?(requested_by)
                    name = requested_by[:identity] || requested_by['identity'] if requested_by.respond_to?(:key?)
                    return name if name && name.to_s != ''
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

              define_method(:identity_caller_hash) do |rack_env|
                request_identity = identity_request_from_env(rack_env)
                if request_identity.respond_to?(:to_caller_hash)
                  caller_hash = request_identity.to_caller_hash
                  if caller_hash.is_a?(Hash)
                    requested_by = caller_hash[:requested_by] || caller_hash['requested_by']
                    return { requested_by: requested_by } if requested_by && !Legion::LLM::PublisherIdentity.generic_requested_by?(requested_by)
                  end
                end

                {
                  requested_by: Legion::LLM::PublisherIdentity.requested_by
                }
              end

              define_method(:build_server_caller) do |source:, path:, env:, caller_context: nil|
                normalized_caller = caller_context.respond_to?(:transform_keys) ? caller_context.transform_keys(&:to_sym) : {}
                safe_caller_fields = normalized_caller.slice(:context, :session_id, :trace_id)

                {
                  source:       source,
                  path:         path,
                  requested_by: identity_caller_hash(env).fetch(:requested_by)
                }.merge(safe_caller_fields)
              end

              define_method(:token_value) do |tokens, key|
                return nil if tokens.nil?
                return tokens[key] || tokens[key.to_s] if tokens.is_a?(Hash)

                method_name = { input: :input_tokens, output: :output_tokens, total: :total_tokens }[key]
                return tokens.public_send(method_name) if method_name && tokens.respond_to?(method_name)

                nil
              end

              define_method(:build_response_metrics) do |pipeline_response|
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
            end

            log.debug('[llm][api][helpers] shared helpers registered')
          end
        end
      end
    end
  end
end
