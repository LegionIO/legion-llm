# frozen_string_literal: true

module RubyLLM
  module Providers
    class Vllm < OpenAI
      module Chat
        def format_role(role)
          role.to_s
        end

        def format_messages(messages)
          messages.map do |msg|
            {
              role:         format_role(msg.role),
              content:      OpenAI::Media.format_content(msg.content),
              tool_calls:   format_tool_calls(msg.tool_calls),
              tool_call_id: msg.tool_call_id
            }.compact.merge(OpenAI::Chat.format_thinking(msg))
          end
        end

        def render_payload(messages, tools:, temperature:, model:, stream: false, schema: nil,
                           thinking: nil, tool_prefs: nil)
          payload = super
          payload[:chat_template_kwargs] = { enable_thinking: true }
          payload
        end
      end

      include Vllm::Chat

      def api_base
        @config.vllm_api_base
      end

      def headers
        return {} unless @config.vllm_api_key

        { 'Authorization' => "Bearer #{@config.vllm_api_key}" }
      end

      class << self
        def configuration_options
          %i[vllm_api_base vllm_api_key]
        end

        def configuration_requirements
          %i[vllm_api_base]
        end

        def local?
          true
        end

        def capabilities
          nil
        end
      end
    end
  end
end

RubyLLM::Provider.register :vllm, RubyLLM::Providers::Vllm
