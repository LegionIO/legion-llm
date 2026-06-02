# frozen_string_literal: true

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
          log.debug "[llm][executor] action=native_tool_loop.enter max_rounds=#{max_rounds} messages=#{messages.size}"

          loop do
            @native_tool_loop_round = round
            result = dispatch_provider_request(capability: :chat, operation: :chat, messages: messages)
            result = Call::NativeResponseAdapter.coerce_result(result)
            tool_calls = normalize_native_tool_calls(result[:tool_calls])
            if tool_calls.empty?
              log.debug "[llm][executor] action=native_tool_loop.complete rounds=#{round} reason=no_tool_calls"
              return result
            end
            if tool_calls.any? { |tool_call| client_passthrough_tool_call?(tool_call) }
              passthrough_names = tool_calls.select { |tc| client_passthrough_tool_call?(tc) }.map { |tc| tc[:name] }.join(',')
              log.info "[llm][native_tool_loop] action=client_passthrough_detected round=#{round} tools=#{passthrough_names}"
              return client_passthrough_tool_loop_result(result, tool_calls, round)
            end

            round += 1
            tool_names = tool_calls.map { |tc| tc[:name] }.join(',')
            log.debug "[llm][executor] action=native_tool_loop.round round=#{round} tool_count=#{tool_calls.size} tools=#{tool_names}"
            if round > max_rounds
              log.warn "[llm][native_tool_loop] action=max_rounds_exceeded max_rounds=#{max_rounds} last_tools=#{tool_names}"
              raise Legion::LLM::PipelineError, "tool loop exceeded #{max_rounds} rounds"
            end

            messages << native_assistant_tool_message(result, tool_calls)
            execute, deferred = split_tool_calls_by_cap(tool_calls, round)
            execute.each do |tool_call|
              messages << native_tool_result_message(tool_call, dispatch_native_tool_call(tool_call, round))
            end
            deferred.each do |tool_call|
              messages << native_tool_result_message(tool_call, deferred_tool_call_result(tool_call))
            end
          end
        ensure
          @native_tool_loop_round = nil
        end

        def execute_native_streaming_tool_loop(&block)
          messages = native_dispatch_messages.dup
          max_rounds = Legion::Settings[:llm][:max_tool_rounds].to_i
          max_rounds = 200 unless max_rounds.positive?
          round = 0
          log.debug "[llm][executor] action=native_streaming_tool_loop.enter max_rounds=#{max_rounds} messages=#{messages.size}"

          loop do
            @native_tool_loop_round = round
            result = dispatch_provider_request(
              capability:   :stream,
              operation:    :chat,
              messages:     messages,
              stream_block: block
            )
            result = Call::NativeResponseAdapter.coerce_result(result)
            tool_calls = normalize_native_tool_calls(result[:tool_calls])
            if tool_calls.empty?
              log.debug "[llm][executor] action=native_streaming_tool_loop.complete rounds=#{round} reason=no_tool_calls"
              return result
            end
            if tool_calls.any? { |tool_call| client_passthrough_tool_call?(tool_call) }
              passthrough_names = tool_calls.select { |tc| client_passthrough_tool_call?(tc) }.map { |tc| tc[:name] }.join(',')
              log.info "[llm][native_tool_loop] action=client_passthrough_detected round=#{round} tools=#{passthrough_names}"
              return client_passthrough_tool_loop_result(result, tool_calls, round)
            end

            round += 1
            tool_names = tool_calls.map { |tc| tc[:name] }.join(',')
            log.debug "[llm][executor] action=native_streaming_tool_loop.round round=#{round} tool_count=#{tool_calls.size} tools=#{tool_names}"
            if round > max_rounds
              log.warn "[llm][native_tool_loop] action=max_rounds_exceeded max_rounds=#{max_rounds} last_tools=#{tool_names}"
              raise Legion::LLM::PipelineError, "tool loop exceeded #{max_rounds} rounds"
            end

            messages << native_assistant_tool_message(result, tool_calls)
            execute, deferred = split_tool_calls_by_cap(tool_calls, round)
            execute.each do |tool_call|
              messages << native_tool_result_message(tool_call, dispatch_native_tool_call(tool_call, round))
            end
            deferred.each do |tool_call|
              messages << native_tool_result_message(tool_call, deferred_tool_call_result(tool_call))
            end
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
              if client_tools_only?
                log.warn "[llm][native_tool_loop] action=tool_choice_forced_passthrough forced_tool=#{explicit_choice} provider=#{@resolved_provider}"
              else
                log.info "[llm][native_tool_loop] action=tool_choice_forced forced_tool=#{explicit_choice} provider=#{@resolved_provider}"
              end
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
          return if client_tools_only?

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
