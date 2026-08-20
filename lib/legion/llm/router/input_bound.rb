# frozen_string_literal: true

module Legion
  module LLM
    module Router
      # Conservative provider-neutral pre-selection input token upper bound (SSOT v3 §9.1).
      #
      # The bound is deliberately over-estimated: one token cannot require more than one
      # input byte under any currently admitted encoding contract. We therefore sum UTF-8
      # byte lengths of all textual content and canonical JSON-serialised byte lengths of
      # structured inputs, then add the configured framing overhead. No chars/4 heuristic,
      # no tokenizer call, no Float arithmetic, no provider-specific estimation.
      #
      # This bound gates hard admission decisions before a lane is selected. Existing
      # TokenEstimation/ContextAccounting helpers remain available for telemetry and
      # post-selection curation but their output cannot authorize a lane.
      module InputBound
        include Legion::Logging::Helper

        class << self
          include Legion::Logging::Helper

          # Returns a nonnegative Integer upper bound on the number of tokens required to
          # represent all supplied inputs.
          #
          # @param operation            [Symbol]  the canonical operation (unused here; present
          #                             for call-site symmetry with RequiredCapabilities)
          # @param messages             [Array, nil]  canonical message hashes/objects
          # @param system               [String, nil] system prompt text
          # @param tools                [Array, nil]  canonical tool-schema objects/hashes
          # @param tool_choice          [Hash, nil]   canonical tool-choice value
          # @param thinking             [Hash, nil]   thinking configuration hash
          # @param response_format      [Hash, nil]   response format hash
          # @param operation_payload    [Hash, nil]   operation-specific extra payload
          # @param framing_overhead_tokens [Integer]  configured framing overhead (e.g. from
          #                             SettingsSnapshot#input_framing_overhead_tokens)
          # @return [Integer] nonnegative token upper bound
          def call(
            messages: nil,
            system: nil,
            tools: nil,
            tool_choice: nil,
            thinking: nil,
            response_format: nil,
            operation_payload: nil,
            framing_overhead_tokens: 0,
            **
          )
            total = 0

            # System prompt
            total = Integer(total) + text_bytes(system)

            # Messages: each message may have String content or Array-of-content-blocks
            Array(messages).each do |msg|
              total += message_text_bytes(msg)
            end

            # Structured inputs serialised to canonical JSON
            total += serialized_bytes(tools)          unless nil_or_empty?(tools)
            total += serialized_bytes(tool_choice)    unless nil_or_empty?(tool_choice)
            total += serialized_bytes(thinking)       unless nil_or_empty?(thinking)
            total += serialized_bytes(response_format) unless nil_or_empty?(response_format)
            total += serialized_bytes(operation_payload) unless nil_or_empty?(operation_payload)

            # Framing overhead (caller-supplied configured Integer)
            overhead = Integer(framing_overhead_tokens.to_i)
            raise ArgumentError, "framing_overhead_tokens must be nonnegative, got #{overhead}" if overhead.negative?

            total += overhead

            log.debug("[llm][input_bound] action=compute total_bytes=#{total}")
            total
          end

          private

          # UTF-8 byte length of a String, or 0 for nil/empty.
          def text_bytes(str)
            return 0 if str.nil?

            s = str.to_s
            return 0 if s.empty?

            s.encode('UTF-8', invalid: :replace, undef: :replace).bytesize
          end

          # Sum all text bytes in a single canonical message hash or object.
          # Handles two shapes:
          #   1. { content: "string" }
          #   2. { content: [ { type: "text", text: "..." }, { type: "image", ... }, ... ] }
          # Defensive: unknown shapes contribute 0, never raise.
          def message_text_bytes(msg)
            return 0 if msg.nil?

            content = msg_field(msg, :content)
            return 0 if content.nil?

            case content
            when String
              text_bytes(content)
            when Array
              content.sum { |block| content_block_bytes(block) }
            else
              0
            end
          end

          # Byte accounting for one content block. Dual-shape: Hash block
          # (client-wire shape) or Canonical::ContentBlock (pipeline shape).
          def content_block_bytes(block)
            return 0 if block.nil?

            type = block_field(block, :type)
            case type&.to_s
            when 'text'
              text_bytes(block_field(block, :text))
            when 'tool_use'
              # tool_use blocks carry a name and input; serialize input for byte accounting
              name_bytes = text_bytes(block_field(block, :name))
              input = block_field(block, :input)
              input_bytes = nil_or_empty?(input) ? 0 : serialized_bytes(input)
              name_bytes + input_bytes
            when 'tool_result'
              result_content = block_field(block, :content) || block_field(block, :text)
              case result_content
              when String then text_bytes(result_content)
              when Array  then result_content.sum { |b| text_bytes(block_field(b, :text)) }
              else 0
              end
            when 'thinking', 'redacted_thinking'
              text_bytes(block_field(block, :thinking) || block_field(block, :text))
            else
              0
            end
          end

          # Dual-shape message field reader (Hash or Canonical::Message).
          def msg_field(msg, field)
            return msg[field] || msg[field.to_s] if msg.is_a?(Hash)

            msg.respond_to?(field) ? msg.public_send(field) : nil
          end

          # Dual-shape content-block field reader (Hash or Canonical::ContentBlock).
          def block_field(block, field)
            return block[field] || block[field.to_s] if block.is_a?(Hash)

            block.respond_to?(field) ? block.public_send(field) : nil
          end

          # Serialize any Ruby value to UTF-8 JSON bytes using Legion::JSON.
          def serialized_bytes(value)
            Legion::JSON.dump(value).bytesize
          end

          def nil_or_empty?(value)
            case value
            when nil    then true
            when String then value.strip.empty?
            when Array, Hash then value.empty?
            else false
            end
          end
        end
      end
    end
  end
end
