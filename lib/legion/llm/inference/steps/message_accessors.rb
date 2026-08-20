# frozen_string_literal: true

module Legion
  module LLM
    module Inference
      module Steps
        # Dual-shape message readers shared by pipeline steps.
        #
        # 0.8.0: the pipeline carries Array<Canonical::Message> (the
        # Inference::Request entry canonicalizes inbound messages). Steps that
        # predate canonicalization read messages with Hash indexing; these
        # helpers read both shapes so a step works whether it receives
        # Canonical::Message objects (the pipeline) or Hash messages (direct
        # step-method specs). Canonical messages are immutable, so content
        # "writes" return a rebuilt message rather than mutating.
        module MessageAccessors
          private

          # => role as a String ('user', 'assistant', 'tool', 'system', ...).
          def message_role_of(message)
            return (message[:role] || message['role']).to_s if message.is_a?(Hash)

            message.respond_to?(:role) ? message.role.to_s : ''
          end

          # => the message's raw content (String, Array<ContentBlock>, or nil).
          def message_content_of(message)
            return message[:content] || message['content'] if message.is_a?(Hash)

            message.respond_to?(:content) ? message.content : nil
          end

          # => plain extracted text (handles canonical .text and Hash content).
          def message_text_of(message)
            return message_content_of(message).to_s if message.is_a?(Hash)

            message.respond_to?(:text) ? message.text.to_s : message_content_of(message).to_s
          end

          # => a NEW message with its content replaced. Canonical messages are
          # rebuilt via .with; Hash messages are dup'd and updated in place.
          def message_with_content(message, content)
            if message.is_a?(Hash)
              updated = message.dup
              key = updated.key?('content') ? 'content' : :content
              updated[key] = content
              updated
            elsif message.respond_to?(:with)
              message.with(content: content)
            else
              message
            end
          end
        end
      end
    end
  end
end
