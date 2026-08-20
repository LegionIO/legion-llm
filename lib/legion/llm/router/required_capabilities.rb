# frozen_string_literal: true

module Legion
  module LLM
    module Router
      # Sole request-shape-to-capability derivation (SSOT v3 §9.2).
      #
      # This is the ONLY place that maps a canonical Inference::Request to a set of routing
      # capability requirements. No route handler, translator, payload builder, executor step,
      # embedding helper, or provider adapter independently derives routing capabilities.
      #
      # The HTTP dialect that produced the request (OpenAI, Anthropic, native) is invisible
      # here. In particular, the OpenAI Responses dialect DOES NOT add a :responses capability
      # — canonical chat/stream_chat operations flow through ordinary operation evidence.
      #
      # @see Legion::Extensions::Llm::Capabilities for the CANONICAL list and normalize/alias rules.
      module RequiredCapabilities
        include Legion::Logging::Helper

        class << self
          include Legion::Logging::Helper

          # Base capabilities required by each operation, independent of request shape.
          OPERATION_BASE = {
            chat:         [].freeze,
            stream_chat:  %i[streaming].freeze,
            embed:        %i[embedding].freeze,
            image:        %i[image].freeze,
            transcribe:   %i[audio_transcription].freeze,
            translate:    [].freeze,
            speak:        %i[audio_speech].freeze,
            moderate:     %i[moderation].freeze,
            count_tokens: [].freeze
          }.freeze

          # Derive the complete frozen capability requirement set for a canonical request.
          #
          # @param request   [Legion::LLM::Inference::Request]  canonical request Data object;
          #                  fields are read defensively — nil/missing fields are treated as
          #                  the requirement not being triggered.
          # @param operation [Symbol]  one of the Phase 1 Taxonomies::OPERATIONS values
          # @return [Array<Symbol>] frozen, normalized, deduplicated canonical capability Symbols
          def call(request:, operation:)
            caps = OPERATION_BASE.fetch(operation, []).dup

            caps << :tools             if tools_required?(request)
            caps << :thinking          if thinking_required?(request)
            caps << :vision            if vision_required?(request)
            caps << :structured_output if structured_output_required?(request)

            result = Legion::Extensions::Llm::Capabilities.normalize(caps)
            log.debug("[llm][required_capabilities] action=derive operation=#{operation} caps=#{result.inspect}")
            result
          end

          private

          # tools: nonempty tool set, tool_choice that requires/names a tool, or any
          # canonical message block of type tool_use or tool_result.
          def tools_required?(request)
            return true if nonempty_array?(request.tools)
            return true if tool_choice_requires_tool?(request.tool_choice)

            messages_contain_block_type?(request.messages, %i[tool_use tool_result])
          end

          # A tool_choice "requires/names a tool" when its mode is neither :auto nor :none.
          # Examples: mode: :tool (specific tool), mode: :any (force some tool call).
          def tool_choice_requires_tool?(tool_choice)
            return false unless tool_choice.is_a?(Hash)

            mode = tool_choice[:mode]
            return false if mode.nil?

            mode_s = mode.to_s
            mode_s != 'auto' && mode_s != 'none'
          end

          # thinking: thinking configuration is enabled OR any message block type is :thinking.
          def thinking_required?(request)
            return true if thinking_config_enabled?(request.thinking)

            messages_contain_block_type?(request.messages, %i[thinking])
          end

          # Thinking is enabled when the config Hash is non-empty and not explicitly disabled.
          # { enabled: false } → disabled. Any other non-empty Hash → enabled.
          def thinking_config_enabled?(thinking)
            return false unless thinking.is_a?(Hash)
            return false if thinking.empty?
            return false if thinking[:enabled] == false

            true
          end

          # vision: any canonical content block type is :image or :image_url.
          # :image_url is required for the current OpenAI translator shape.
          def vision_required?(request)
            messages_contain_block_type?(request.messages, %i[image image_url])
          end

          # structured_output: response_format type is json_object or json_schema,
          # or the response_format contains a nonempty schema.
          def structured_output_required?(request)
            rf = request.response_format
            return false unless rf.is_a?(Hash)

            type_s = rf[:type].to_s
            return true if %w[json_object json_schema].include?(type_s)

            rf[:schema].is_a?(Hash) && !rf[:schema].empty?
          end

          # Iterate all canonical message content blocks and return true if any block has
          # a type in the given set. Handles both String content (no blocks to inspect) and
          # Array-of-block content. Defensive: unrecognized shapes contribute nothing, never raise.
          def messages_contain_block_type?(messages, types)
            return false unless messages.is_a?(Array)

            messages.any? do |message|
              content = message_content_of(message)
              next false unless content.is_a?(Array)

              content.any? do |block|
                block_type = block_type_of(block)
                next false if block_type.nil?

                types.include?(block_type) || types.include?(block_type.to_sym)
              end
            end
          end

          # Canonical Message#content or Hash message content, defensively.
          def message_content_of(message)
            return message[:content] || message['content'] if message.is_a?(Hash)

            message.respond_to?(:content) ? message.content : nil
          end

          # Canonical ContentBlock#type or Hash block :type, defensively.
          def block_type_of(block)
            return block.type if block.respond_to?(:type) && !block.is_a?(Hash)

            block.is_a?(Hash) ? (block[:type] || block['type']) : nil
          end

          def nonempty_array?(value)
            value.is_a?(Array) && !value.empty?
          end
        end
      end
    end
  end
end
