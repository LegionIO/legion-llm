# frozen_string_literal: true

require 'digest'

module Legion
  module LLM
    # Canonical SHA-256 content hash used wherever an opaque, deterministic
    # fingerprint of textual content is needed (audit ledger request_content_hash /
    # response_content_hash, embedding cache keys, RAG document IDs, etc.). One
    # implementation, one normalization, so records join across systems (G19a).
    #
    # Accepts either:
    #   - String / nil
    #   - Array<Hash> (message-shaped: each entry's :content or 'content' key)
    #   - any other object that responds to #to_s
    #
    # Returns the lowercase SHA-256 hex digest, or nil for empty/missing content.
    module ContentHash
      module_function

      def call(content)
        text = normalize(content)
        return nil if text.nil? || text.empty?

        Digest::SHA256.hexdigest(text)
      end

      def normalize(content)
        return nil if content.nil?

        if content.is_a?(Array)
          content.map { |m| extract_message_text(m) }.join("\n")
        else
          content.to_s
        end
      end

      def extract_message_text(message)
        return message.to_s unless message.is_a?(Hash)

        # Prefer string-key access (matches AuditPublisher#hash_value precedence
        # so the digest is byte-compatible with previously-emitted ledger rows).
        value = if message.key?('content')
                  message['content']
                elsif message.key?(:content)
                  message[:content]
                end
        (value || message).to_s
      end
    end
  end
end
