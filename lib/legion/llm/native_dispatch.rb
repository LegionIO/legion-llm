# frozen_string_literal: true

module Legion
  module LLM
    # Wraps a native dispatch result hash so it exposes the same interface
    # that RubyLLM response objects expose (used by Pipeline::Executor and
    # ConversationStore after a provider call).
    class NativeResponseAdapter
      attr_reader :content, :input_tokens, :output_tokens,
                  :cache_read_tokens, :cache_write_tokens, :usage

      def initialize(result_hash)
        @content             = result_hash[:result].to_s
        usage                = result_hash[:usage] || Usage.new
        @usage               = usage
        @input_tokens        = usage.input_tokens
        @output_tokens       = usage.output_tokens
        @cache_read_tokens   = usage.cache_read_tokens
        @cache_write_tokens  = usage.cache_write_tokens
      end
    end

    module NativeDispatch
      extend self

      # Dispatch a chat request to a registered lex-* extension.
      #
      # @param provider [Symbol, String] provider name
      # @param model    [String, nil]   model identifier forwarded to the extension
      # @param messages [Array<Hash>]   array of { role:, content: } message hashes
      # @return [Hash] standardized { result:, usage: } hash
      # @raise [Legion::LLM::ProviderError] if provider is not registered
      def dispatch_chat(provider:, model:, messages:, **)
        ext = fetch_extension!(provider)
        raw = ext.chat(model: model, messages: messages, **)
        normalize_response(raw)
      end

      # Dispatch an embedding request to a registered lex-* extension.
      #
      # @param provider [Symbol, String] provider name
      # @param model    [String, nil]   model identifier
      # @param text     [String]        text to embed
      # @return [Hash] standardized { result:, usage: } hash
      # @raise [Legion::LLM::ProviderError] if provider is not registered
      def dispatch_embed(provider:, model:, text:, **)
        ext = fetch_extension!(provider)
        raw = ext.embed(model: model, text: text, **)
        normalize_response(raw)
      end

      # Dispatch a streaming chat request to a registered lex-* extension.
      #
      # @param provider [Symbol, String] provider name
      # @param model    [String, nil]   model identifier
      # @param messages [Array<Hash>]   message hashes
      # @param block    [Proc]          receives each chunk as it arrives
      # @return [Hash] standardized { result:, usage: } hash
      # @raise [Legion::LLM::ProviderError] if provider is not registered
      def dispatch_stream(provider:, model:, messages:, **, &)
        ext = fetch_extension!(provider)
        raw = ext.stream(model: model, messages: messages, **, &)
        normalize_response(raw)
      end

      # Dispatch a token count request to a registered lex-* extension.
      #
      # @param provider [Symbol, String] provider name
      # @param model    [String, nil]   model identifier
      # @param messages [Array<Hash>]   message hashes
      # @return [Hash] standardized { result:, usage: } hash
      # @raise [Legion::LLM::ProviderError] if provider is not registered
      def dispatch_count_tokens(provider:, model:, messages:, **)
        ext = fetch_extension!(provider)
        raw = ext.count_tokens(model: model, messages: messages, **)
        normalize_response(raw)
      end

      # Returns true when the provider is registered in ProviderRegistry.
      #
      # @param provider [Symbol, String]
      # @return [Boolean]
      def available?(provider)
        ProviderRegistry.registered?(provider)
      end

      private

      def fetch_extension!(provider)
        ext = ProviderRegistry.for(provider)
        return ext if ext

        raise Legion::LLM::ProviderError,
              "Native provider not registered: #{provider}. " \
              'Ensure the lex-* extension is loaded before dispatching.'
      end

      # Normalize a raw extension response into a standard hash.
      #
      # Expected extension return shapes (any subset is acceptable):
      #   { content:, usage: { input_tokens:, output_tokens: }, model: }
      #   { result:, usage: ... }
      #
      # Normalizes to: { result:, usage: Usage }
      def normalize_response(raw)
        return { result: raw, usage: Usage.new } unless raw.is_a?(Hash)

        result    = raw[:result] || raw[:content] || raw[:response]
        raw_usage = raw[:usage] || {}

        usage = if raw_usage.is_a?(Usage)
                  raw_usage
                elsif raw_usage.is_a?(Hash)
                  Usage.new(
                    input_tokens:       raw_usage[:input_tokens].to_i,
                    output_tokens:      raw_usage[:output_tokens].to_i,
                    cache_read_tokens:  raw_usage[:cache_read_tokens].to_i,
                    cache_write_tokens: raw_usage[:cache_write_tokens].to_i
                  )
                else
                  Usage.new
                end

        { result: result, usage: usage }
      end
    end
  end
end
