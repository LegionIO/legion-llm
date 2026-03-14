# frozen_string_literal: true

# Monkey-patch RubyLLM's Bedrock provider to support AWS Bearer Token
# authentication (Identity Center / SSO) as an alternative to SigV4.
#
# When `bedrock_bearer_token` is set on the RubyLLM configuration,
# requests use a simple `Authorization: Bearer <token>` header instead
# of the full SigV4 signing process.

require 'ruby_llm'

module RubyLLM
  class Configuration
    attr_accessor :bedrock_bearer_token
  end

  module Providers
    class Bedrock
      class << self
        def configuration_requirements
          config = RubyLLM.config
          if config.bedrock_bearer_token
            %i[bedrock_bearer_token bedrock_region]
          else
            %i[bedrock_api_key bedrock_secret_key bedrock_region]
          end
        end
      end

      module Auth
        private

        alias_method :sigv4_sign_headers, :sign_headers

        def sign_headers(method, path, body, base_url: api_base)
          if @config.bedrock_bearer_token
            bearer_headers(path, body)
          else
            sigv4_sign_headers(method, path, body, base_url: base_url)
          end
        end

        def bearer_headers(_path, body)
          {
            'Authorization'        => "Bearer #{@config.bedrock_bearer_token}",
            'Content-Type'         => 'application/json',
            'X-Amz-Content-Sha256' => Digest::SHA256.hexdigest(body)
          }
        end
      end
    end
  end
end
