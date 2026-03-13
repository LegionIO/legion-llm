# frozen_string_literal: true

require 'ruby_llm'
require 'legion/llm/version'
require 'legion/llm/settings'
require 'legion/llm/providers'

module Legion
  module LLM
    class << self
      include Legion::LLM::Providers

      def start
        Legion::Logging.debug 'Legion::LLM is running start'

        configure_providers
        set_defaults

        @started = true
        Legion::Settings[:llm][:connected] = true
        Legion::Logging.info 'Legion::LLM started'
      end

      def shutdown
        Legion::Settings[:llm][:connected] = false
        @started = false
        Legion::Logging.info 'Legion::LLM shut down'
      end

      def started?
        @started == true
      end

      def settings
        if Legion.const_defined?('Settings')
          Legion::Settings[:llm]
        else
          Legion::LLM::Settings.default
        end
      end

      # Create a new chat session
      # @param model [String] model ID (e.g., "us.anthropic.claude-sonnet-4-6-v1")
      # @param provider [Symbol] provider slug (e.g., :bedrock, :anthropic)
      # @param kwargs [Hash] additional options passed to RubyLLM.chat
      # @return [RubyLLM::Chat]
      def chat(model: nil, provider: nil, **kwargs)
        model    ||= settings[:default_model]
        provider ||= settings[:default_provider]

        opts = {}
        opts[:model]    = model    if model
        opts[:provider] = provider if provider
        opts.merge!(kwargs)

        RubyLLM.chat(**opts)
      end

      # Generate embeddings
      # @param text [String, Array<String>] text to embed
      # @param model [String] embedding model ID
      # @return [RubyLLM::Embedding]
      def embed(text, model: nil)
        if model
          RubyLLM.embed(text, model: model)
        else
          RubyLLM.embed(text)
        end
      end

      # Create a configured agent instance
      # @param agent_class [Class] a RubyLLM::Agent subclass
      # @param kwargs [Hash] additional options
      # @return [RubyLLM::Agent]
      def agent(agent_class, **kwargs)
        agent_class.new(**kwargs)
      end

      private

      def set_defaults
        default_model    = settings[:default_model]
        default_provider = settings[:default_provider]

        RubyLLM.configure do |c|
          c.default_model = default_model if default_model
        end

        return unless default_model.nil? && default_provider.nil?

        # Auto-detect: use first enabled provider's sensible default
        auto_configure_defaults
      end

      def auto_configure_defaults
        provider_defaults = {
          bedrock:   { model: 'us.anthropic.claude-sonnet-4-6-v1', provider: :bedrock },
          anthropic: { model: 'claude-sonnet-4-6', provider: :anthropic },
          openai:    { model: 'gpt-4o', provider: :openai },
          gemini:    { model: 'gemini-2.0-flash', provider: :gemini },
          ollama:    { model: 'llama3', provider: :ollama }
        }

        provider_defaults.each do |provider, defaults|
          config = settings[:providers][provider]
          next unless config&.dig(:enabled)

          settings[:default_model]    = defaults[:model]
          settings[:default_provider] = defaults[:provider]
          Legion::Logging.info "Auto-configured default: #{defaults[:model]} via #{defaults[:provider]}"
          break
        end
      end
    end
  end
end
