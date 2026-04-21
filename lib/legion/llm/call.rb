# frozen_string_literal: true

require_relative 'call/registry'
require_relative 'call/dispatch'
require_relative 'call/providers'
require_relative 'call/embeddings'
require_relative 'call/structured_output'
require_relative 'call/daemon_client'
require_relative 'call/bedrock_auth'
require_relative 'call/claude_config_loader'
require_relative 'call/codex_config_loader'

module Legion
  module LLM
    module Call
    end
  end
end
