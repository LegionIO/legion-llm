# frozen_string_literal: true

require 'securerandom'
require 'open3'
require 'time'
require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Native
        module ClientToolMethods
          private

          def log_tool(level, ref, status, **details)
            parts = ["[tool][#{ref}] #{status}"]
            details.each { |k, v| parts << "#{k}=#{v}" }
            Legion::Logging.send(level, parts.join(' '))
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

          def dispatch_client_tool(ref, **kwargs) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity
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
              raw_max_length = kwargs[:maxLength] || kwargs[:max_length]
              max_length = raw_max_length.nil? ? nil : [raw_max_length.to_i, 0].max
              begin
                require 'legion/cli/chat/web_fetch'
                content = Legion::CLI::Chat::WebFetch.fetch(url)
                max_length ? content[0, max_length] : content
              rescue LoadError => e
                missing = e.respond_to?(:path) && e.path ? e.path : 'legion/cli/chat/web_fetch'
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
                "web_search is unavailable: missing optional dependency #{missing}"
              end
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

        module Helpers
          extend Legion::Logging::Helper

          def self.registered(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
            log.debug('[llm][api][helpers] registering shared helpers')

            app.helpers do # rubocop:disable Metrics/BlockLength
              include Legion::Logging::Helper

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
                  defined?(Legion::Cache) &&
                    Legion::Cache.respond_to?(:connected?) &&
                    Legion::Cache.connected?
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
                tool_ref = tname
                klass = Class.new(RubyLLM::Tool) do
                  include Legion::LLM::API::Native::ClientToolMethods

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
                    Legion::Logging.log_exception(e, payload_summary: "client tool #{tool_ref} failed",
                                                     component_type:  :api)
                    "Tool error: #{e.message}"
                  end
                end
                klass.params(tschema) if tschema.is_a?(Hash) && tschema[:properties]
                klass
              rescue StandardError => e
                handle_exception(e, level: :warn, handled: true, operation: "llm.api.build_client_tool_class.#{tname}")
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

              define_method(:resolve_caller_identity) do |rack_env|
                return rack_env['legion.tenant_id'] if rack_env['legion.tenant_id']

                kerb = begin
                  Legion::Settings.dig(:kerberos, :username)
                rescue StandardError
                  nil
                end
                return "user:#{kerb}" if kerb.is_a?(String) && !kerb.empty?

                principal = rack_env['legion.principal']
                return "user:#{principal.canonical_name}" if principal.respond_to?(:canonical_name) && principal.canonical_name != 'system'

                if defined?(Legion::Identity::Process)
                  name = Legion::Identity::Process.canonical_name
                  return "user:#{name}" if name && name != 'anonymous'
                end

                raw = ENV.fetch('USER', nil) || ENV.fetch('LOGNAME', nil) || 'anonymous'
                username = raw.include?('@') ? raw.split('@').first : raw
                "user:#{username}"
              end

              define_method(:resolve_requested_by) do |rack_env, identity_string|
                hostname = begin
                  Legion::Settings[:client][:hostname]
                rescue StandardError
                  Socket.gethostname
                end
                username = identity_string.delete_prefix('user:')

                kerb = begin
                  Legion::Settings.dig(:kerberos, :username)
                rescue StandardError
                  nil
                end
                if kerb.is_a?(String) && !kerb.empty?
                  return { identity: identity_string, type: :user, credential: :kerberos,
                           username: kerb, hostname: hostname }
                end

                principal = rack_env['legion.principal']
                if principal.respond_to?(:canonical_name) && principal.canonical_name != 'system'
                  return { identity: identity_string, type: principal.kind || :user,
                           credential: principal.source || :local,
                           username: principal.canonical_name, hostname: hostname }
                end

                { identity: identity_string, type: :user, credential: :local,
                  username: username, hostname: hostname }
              end

              define_method(:token_value) do |tokens, key|
                return nil if tokens.nil?
                return tokens[key] || tokens[key.to_s] if tokens.is_a?(Hash)

                method_name = { input: :input_tokens, output: :output_tokens, total: :total_tokens }[key]
                return tokens.public_send(method_name) if method_name && tokens.respond_to?(method_name)

                nil
              end
            end

            log.debug('[llm][api][helpers] shared helpers registered')
          end
        end
      end
    end
  end
end
