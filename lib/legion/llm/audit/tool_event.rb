# frozen_string_literal: true

require_relative '../transport/message'

module Legion
  module LLM
    module Audit
      class ToolEvent < Legion::LLM::Transport::Message
        def type        = 'llm.audit.tool'
        def exchange    = Legion::LLM::Audit::Exchange
        def routing_key = "audit.tool.#{@options[:tool_name]}"
        def priority    = 0
        def encrypt?    = true
        def expiration  = nil

        def headers
          super.merge(tool_headers).merge(classification_headers)
        end

        private

        def message_id_prefix = 'audit_tool'

        def tool_headers
          tc = @options[:tool_call] || {}
          src = tc[:source] || {}
          h = {}
          h['x-legion-tool-name']          = tc[:name].to_s    if tc[:name]
          h['x-legion-tool-source-type']   = src[:type].to_s   if src[:type]
          h['x-legion-tool-source-server'] = src[:server].to_s if src[:server]
          h['x-legion-tool-status']        = tc[:status].to_s  if tc[:status]
          h
        end

        def classification_headers
          cls = @options[:classification] || {}
          h = {}
          h['x-legion-classification'] = cls[:level].to_s if cls[:level]
          h['x-legion-contains-phi']   = cls[:contains_phi].to_s unless cls[:contains_phi].nil?
          h
        end
      end
    end
  end
end
