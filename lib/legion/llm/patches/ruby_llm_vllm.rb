# frozen_string_literal: true

module RubyLLM
  module Providers
    class Vllm < OpenAI
      module Chat
        module_function

        def format_role(role)
          role.to_s
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
