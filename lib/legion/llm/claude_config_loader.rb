# frozen_string_literal: true

module Legion
  module LLM
    module ClaudeConfigLoader
      CLAUDE_SETTINGS = File.expand_path('~/.claude/settings.json')
      CLAUDE_CONFIG   = File.expand_path('~/.claude.json')

      module_function

      def load
        config = read_json(CLAUDE_SETTINGS).merge(read_json(CLAUDE_CONFIG))
        return if config.empty?

        apply_claude_config(config)
      end

      def read_json(path)
        return {} unless File.exist?(path)

        require 'json'
        ::JSON.parse(File.read(path), symbolize_names: true)
      rescue StandardError
        {}
      end

      def apply_claude_config(config)
        apply_api_keys(config)
        apply_model_preference(config)
      end

      def apply_api_keys(config)
        llm = Legion::LLM.settings
        providers = llm[:providers]

        if config[:anthropicApiKey] && providers.dig(:anthropic, :api_key).nil?
          providers[:anthropic][:api_key] = config[:anthropicApiKey]
          Legion::Logging.debug 'Imported Anthropic API key from Claude CLI config'
        end

        return unless config[:openaiApiKey] && providers.dig(:openai, :api_key).nil?

        providers[:openai][:api_key] = config[:openaiApiKey]
        Legion::Logging.debug 'Imported OpenAI API key from Claude CLI config'
      end

      def apply_model_preference(config)
        return unless config[:preferredModel] || config[:model]

        model = config[:preferredModel] || config[:model]
        llm = Legion::LLM.settings
        return if llm[:default_model]

        llm[:default_model] = model
        Legion::Logging.debug "Imported model preference from Claude CLI config: #{model}"
      end
    end
  end
end
