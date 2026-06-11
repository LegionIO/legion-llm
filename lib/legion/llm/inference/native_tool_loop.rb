# frozen_string_literal: true

require 'digest'

module Legion
  module LLM
    module Inference
      module NativeToolLoop
        private

        def execute_native_tool_loop
          messages = native_dispatch_messages.dup
          max_rounds = Legion::Settings[:llm][:max_tool_rounds].to_i
          max_rounds = 200 unless max_rounds.positive?
          round = 0
          # Track which (tool_name, args) pairs have been executed server-side,
          # and how many consecutive rounds ended in all-server failures.
          executed_calls = {} # "name:hash(args)" => count
          consecutive_failures = 0

          log.debug "[llm][executor] action=native_tool_loop.enter max_rounds=#{max_rounds} messages=#{messages.size}"

          loop do
            @native_tool_loop_round = round
            result = dispatch_provider_request(capability: :chat, operation: :chat, messages: messages)
            tool_calls = extract_tool_calls(result)
            if tool_calls.empty?
              # Provider may have emitted tool arguments as plain text JSON
              # (common with vLLM/qwen when a tool choice is forced).
              # Try to synthesize a structured tool call from the text.
              tool_calls = maybe_synthesize_tool_call_from_content(result, round)
              result = apply_synthesized_tool_calls(result, tool_calls) if tool_calls.any?
            end
            if tool_calls.empty?
              log.debug "[llm][executor] action=native_tool_loop.complete rounds=#{round} reason=no_tool_calls"
              @last_tool_loop_messages = messages
              return result
            end
            # Split tool calls into server-executable (LegionIO) and client-passthrough.
            # Execute LegionIO tools server-side first; return only client tools to
            # the client at the end. This prevents sending LegionIO tool calls to
            # clients (Claude terminal, Codex) that can't execute them.
            server_calls, client_calls = tool_calls.partition { |tc| !client_passthrough_tool_call?(tc) }

            if client_calls.any?
              passthrough_names = client_calls.map { |tc| tc[:name] }.join(',')
              log.info "[llm][native_tool_loop] action=client_passthrough_detected round=#{round} client_tools=#{passthrough_names} server_tools=#{server_calls.map { |tc| tc[:name] }.join(',')}"
            end

            # Execute all LegionIO tools server-side
            unless server_calls.empty?
              round += 1
              tool_names = server_calls.map { |tc| tc[:name] }.join(',')
              log.debug "[llm][executor] action=native_tool_loop.round round=#{round} tool_count=#{server_calls.size} tools=#{tool_names}"
              if round > max_rounds
                log.warn "[llm][native_tool_loop] action=max_rounds_exceeded max_rounds=#{max_rounds} last_tools=#{tool_names}"
                raise Legion::LLM::PipelineError, "tool loop exceeded #{max_rounds} rounds"
              end

              # Detect repeated tool calls before executing again.
              repeated = detect_repeated_tool_calls(server_calls, executed_calls)
              if repeated.any?
                log.warn "[llm][native_tool_loop] action=repeated_tool_calls detected round=#{round} " \
                         "repeated=#{repeated.map { |tc| tc[:name] }.join(',')} total_calls=#{executed_calls.size}"
                # Return failures + any client tools so the client can adapt.
                return client_passthrough_tool_loop_result(result, client_calls, round)
              end

              messages << native_assistant_tool_message(result, server_calls)
              execute, deferred = split_tool_calls_by_cap(server_calls, round)
              round_results = []

              execute.each do |tool_call|
                call_result = dispatch_native_tool_call(tool_call, round)
                round_results << { tool_call: tool_call, result: call_result }
                messages << native_tool_result_message(tool_call, call_result)
              end
              deferred.each do |tool_call|
                deferred_result = deferred_tool_call_result(tool_call)
                round_results << { tool_call: tool_call, result: deferred_result }
                messages << native_tool_result_message(tool_call, deferred_result)
              end

              # Record which calls were executed this round for repeat detection.
              round_results.each do |entry|
                tc = entry[:tool_call]
                call_key = tool_call_key(tc[:name], tc[:arguments] || tc['arguments'])
                executed_calls[call_key] = (executed_calls[call_key] || 0) + 1
              end

              # Check if all tools in this round failed.
              all_failed = round_results.all? { |entry| entry[:result][:status] == :error }
              if all_failed
                consecutive_failures += 1
                failed_names = round_results.map { |e| e[:tool_call][:name] }.join(',')
                log.warn "[llm][native_tool_loop] action=all_server_tools_failed round=#{round} " \
                         "consecutive_failures=#{consecutive_failures} tools=#{failed_names}"
                if consecutive_failures >= 2
                  log.warn "[llm][native_tool_loop] action=server_failure_loop_broken consecutive_failures=#{consecutive_failures}"
                  return client_passthrough_tool_loop_result(result, client_calls, round)
                end
              else
                consecutive_failures = 0
              end
            end

            # If there are client passthrough tools, exit the loop and return them
            # to the client for execution. client_passthrough_tool_loop_result
            # merges server-executed LegionIO tool calls (with results) alongside
            # client tool calls (passthrough) in the result.
            return client_passthrough_tool_loop_result(result, client_calls, round) if client_calls.any?
          end
        ensure
          @native_tool_loop_round = nil
        end

        def execute_native_streaming_tool_loop(&block)
          messages = native_dispatch_messages.dup
          max_rounds = Legion::Settings[:llm][:max_tool_rounds].to_i
          max_rounds = 200 unless max_rounds.positive?
          round = 0
          executed_calls = {}
          consecutive_failures = 0

          log.debug "[llm][executor] action=native_streaming_tool_loop.enter max_rounds=#{max_rounds} messages=#{messages.size}"

          loop do
            @native_tool_loop_round = round
            result = dispatch_provider_request(
              capability:   :stream,
              operation:    :chat,
              messages:     messages,
              stream_block: block
            )
            tool_calls = extract_tool_calls(result)
            if tool_calls.empty?
              tool_calls = maybe_synthesize_tool_call_from_content(result, round)
              result = apply_synthesized_tool_calls(result, tool_calls) if tool_calls.any?
            end
            if tool_calls.empty?
              log.debug "[llm][executor] action=native_streaming_tool_loop.complete rounds=#{round} reason=no_tool_calls"
              @last_tool_loop_messages = messages
              return result
            end
            server_calls, client_calls = tool_calls.partition { |tc| !client_passthrough_tool_call?(tc) }

            if client_calls.any?
              passthrough_names = client_calls.map { |tc| tc[:name] }.join(',')
              log.info "[llm][native_tool_loop] action=client_passthrough_detected round=#{round} client_tools=#{passthrough_names} server_tools=#{server_calls.map { |tc| tc[:name] }.join(',')}"
            end

            unless server_calls.empty?
              round += 1
              tool_names = server_calls.map { |tc| tc[:name] }.join(',')
              log.debug "[llm][native_tool_loop] action=native_streaming_tool_loop.round round=#{round} tool_count=#{server_calls.size} tools=#{tool_names}"
              if round > max_rounds
                log.warn "[llm][native_tool_loop] action=max_rounds_exceeded max_rounds=#{max_rounds} last_tools=#{tool_names}"
                raise Legion::LLM::PipelineError, "tool loop exceeded #{max_rounds} rounds"
              end

              repeated = detect_repeated_tool_calls(server_calls, executed_calls)
              if repeated.any?
                log.warn "[llm][native_tool_loop] action=repeated_tool_calls detected round=#{round} " \
                         "repeated=#{repeated.map { |tc| tc[:name] }.join(',')} total_calls=#{executed_calls.size}"
                return client_passthrough_tool_loop_result(result, client_calls, round)
              end

              messages << native_assistant_tool_message(result, server_calls)
              execute, deferred = split_tool_calls_by_cap(server_calls, round)
              round_results = []

              execute.each do |tool_call|
                call_result = dispatch_native_tool_call(tool_call, round)
                round_results << { tool_call: tool_call, result: call_result }
                messages << native_tool_result_message(tool_call, call_result)
              end
              deferred.each do |tool_call|
                deferred_result = deferred_tool_call_result(tool_call)
                round_results << { tool_call: tool_call, result: deferred_result }
                messages << native_tool_result_message(tool_call, deferred_result)
              end

              round_results.each do |entry|
                tc = entry[:tool_call]
                call_key = tool_call_key(tc[:name], tc[:arguments] || tc['arguments'])
                executed_calls[call_key] = (executed_calls[call_key] || 0) + 1
              end

              all_failed = round_results.all? { |entry| entry[:result][:status] == :error }
              if all_failed
                consecutive_failures += 1
                failed_names = round_results.map { |e| e[:tool_call][:name] }.join(',')
                log.warn "[llm][native_tool_loop] action=all_server_tools_failed round=#{round} " \
                         "consecutive_failures=#{consecutive_failures} tools=#{failed_names}"
                if consecutive_failures >= 2
                  log.warn "[llm][native_tool_loop] action=server_failure_loop_broken consecutive_failures=#{consecutive_failures}"
                  return client_passthrough_tool_loop_result(result, client_calls, round)
                end
              else
                consecutive_failures = 0
              end
            end

            return client_passthrough_tool_loop_result(result, client_calls, round) if client_calls.any?
          end
        ensure
          @native_tool_loop_round = nil
        end

        def split_tool_calls_by_cap(tool_calls, round)
          max_per_turn = Legion::Settings[:llm][:max_tool_calls_per_turn].to_i
          return [tool_calls, []] unless max_per_turn.positive? && tool_calls.size > max_per_turn

          log.warn "[llm][native_tool_loop] action=cap_per_turn round=#{round} " \
                   "total=#{tool_calls.size} limit=#{max_per_turn} deferred=#{tool_calls.size - max_per_turn}"
          [tool_calls.first(max_per_turn), tool_calls[max_per_turn..]]
        end

        def deferred_tool_call_result(tool_call)
          {
            status:      :error,
            result:      "Tool call deferred: too many concurrent tool calls this turn. Please retry #{tool_call[:name]} on your next turn.",
            duration_ms: 0
          }
        end

        def native_tool_prefs
          choice = @request.tool_choice
          calls = nil

          if choice.is_a?(Hash)
            normalized = choice.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
            mode = normalized[:choice] || normalized[:mode] || normalized[:type]
            mode_sym = mode.respond_to?(:to_sym) ? mode.to_sym : nil
            choice = if %i[tool function named].include?(mode_sym) && normalized[:name]
                       normalized[:name]
                     else
                       mode
                     end
            calls = normalized[:calls]
          end

          prefs = {}
          normalized_choice = normalize_native_tool_choice(choice) if choice
          if normalized_choice.to_s == 'auto'
            explicit_choice = explicit_native_tool_choice
            if explicit_choice && @native_tool_loop_round.to_i.zero?
              log.info "[llm][native_tool_loop] action=tool_choice_forced forced_tool=#{explicit_choice} provider=#{@resolved_provider}"
              normalized_choice = explicit_choice
            end
          end
          prefs[:choice] = normalized_choice if normalized_choice
          prefs[:calls] = calls if calls
          log.debug "[llm][native_tool_loop] action=tool_prefs_resolved choice=#{prefs[:choice] || 'none'} calls=#{prefs[:calls] || 'none'}" unless prefs.empty?
          prefs.empty? ? nil : prefs
        end

        def normalize_native_tool_choice(choice)
          return choice if choice.is_a?(Symbol)

          choice.to_s
        end

        def explicit_native_tool_choice
          return unless @resolved_provider.to_s == 'vllm'

          text = latest_user_text.to_s.downcase
          return if text.empty? || text.length > 500

          match = native_dispatch_tools.keys.map(&:to_s).sort_by { |tool_name| -tool_name.length }.find do |tool_name|
            explicit_tool_name_mentioned?(text, tool_name)
          end
          log.info "[llm][native_tool_loop] action=explicit_tool_choice_matched tool=#{match} text_length=#{text.length}" if match
          match
        end

        def explicit_tool_name_mentioned?(text, tool_name)
          explicit_tool_name_candidates(tool_name).any? do |candidate|
            text.match?(/(?<![[:alnum:]_-])#{Regexp.escape(candidate)}(?![[:alnum:]_-])/)
          end
        end

        def explicit_tool_name_candidates(tool_name)
          normalized_name = tool_name.to_s.downcase
          [
            normalized_name,
            normalized_name.tr('_-', ' '),
            normalized_name.tr('_', '-'),
            normalized_name.tr('-', '_')
          ].reject(&:empty?).uniq
        end

        def latest_user_text
          message = Array(@request.messages).reverse.find do |msg|
            msg.is_a?(Hash) && (msg[:role] || msg['role']).to_s == 'user'
          end
          return '' unless message

          content = message[:content] || message['content']
          return content.to_s unless content.is_a?(Array)

          content.filter_map do |part|
            next part if part.is_a?(String)
            next unless part.is_a?(Hash)

            part[:text] || part['text']
          end.join(' ')
        end

        # When a tool choice is forced and the provider outputs the arguments as
        # plain text JSON (e.g. vLLM/qwen), synthesize a structured tool call
        # from the content so downstream translators emit the correct
        # client-native shape (tool_use / function_call etc).
        #
        # Returns an array of synthesized tool call hashes. Does NOT mutate the
        # result — the caller rebuilds the canonical response if synthesis occurs.
        def maybe_synthesize_tool_call_from_content(result, round)
          tool_prefs = native_tool_prefs
          return [] unless tool_prefs

          forced_name = tool_prefs[:choice]
          return [] unless forced_name && native_dispatch_tools.key?(forced_name)

          text = result_text_for_synthesis(result)
          return [] if text.empty? || !text.start_with?('{"')

          parsed = nil
          begin
            parsed = Legion::JSON.parse(text, symbolize_names: false)
          rescue Legion::JSON::ParseError, StandardError => e
            log.warn "[llm][native_tool_loop] action=synthesize_tool_call failed parse round=#{round} error=#{e.message}"
            return []
          end
          return [] unless parsed.is_a?(Hash) && !parsed.empty?

          synthesized = [{
            id:        "call_#{SecureRandom.hex(10)}",
            name:      forced_name.to_s,
            arguments: parsed
          }]

          log.info "[llm][native_tool_loop] action=synthesized_tool_call round=#{round} " \
                   "tool=#{forced_name} arg_keys=#{parsed.keys.join(',')}"

          synthesized
        end

        # Extract text from canonical or hash-shaped result for tool-call synthesis.
        def result_text_for_synthesis(result)
          result.respond_to?(:text) ? result.text.to_s.strip :
            (result[:result] || result[:content] || result['result'] || result['content'] || '').to_s.strip
        end

        # Apply synthesized tool calls to a canonical response (using .with for immutability)
        # or mutate a hash in place. Returns the updated response.
        def apply_synthesized_tool_calls(result, tool_calls)
          return result.merge(tool_calls: tool_calls, stop_reason: :tool_use) unless result.respond_to?(:with)

          result.with(
            text:       '',
            tool_calls: tool_calls,
            stop_reason: :tool_use
          )
        end

        # Detect tool calls that have already been executed in a previous round
        # of this loop. Returns the subset of tool_calls that are repeats.
        def detect_repeated_tool_calls(tool_calls, executed_calls)
          tool_calls.select do |tc|
            call_key = tool_call_key(tc[:name], tc[:arguments] || tc['arguments'])
            executed_calls.key?(call_key)
          end
        end

        # Build a stable key for repeat detection: tool name + hash of arguments.
        def tool_call_key(name, args)
          arg_value = if args.is_a?(String)
                        args
                      else
                        (args ? ::JSON.dump(args) : '{}')
                      end
          "name=#{name}:args_hash=#{::Digest::MD5.hexdigest(arg_value)}"
        rescue StandardError
          "name=#{name}:args_hash=default"
        end

        # Extract tool call array from canonical response or hash-shaped result.
        def extract_tool_calls(result)
          return result.tool_calls if result.respond_to?(:tool_calls) && result.respond_to?(:text)

          # Fallback for hash-shaped results
          (result[:tool_calls] || result['tool_calls'] || []).to_a
        end

        def normalize_native_tool_calls(tool_calls)
          Array(tool_calls).filter_map do |tool_call|
            normalized = normalize_native_tool_call(tool_call)
            next if normalized[:name].to_s.empty?

            normalized
          end
        end
      end
    end
  end
end
