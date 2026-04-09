# frozen_string_literal: true

require_relative '../transport/message'

module Legion
  module LLM
    module Audit
      class PromptEvent < Legion::LLM::Transport::Message
        def type        = 'llm.audit.prompt'
        def exchange    = Legion::LLM::Audit::Exchange
        def routing_key = "audit.prompt.#{@options[:request_type]}"
        def priority    = 0
        def encrypt?    = true
        def expiration  = nil

        def headers
          super.merge(classification_headers).merge(caller_headers).merge(retention_headers).merge(tier_header)
        end

        private

        def message_id_prefix = 'audit_prompt'

        def classification_headers
          cls = @options[:classification] || {}
          h = {}
          h['x-legion-classification'] = cls[:level].to_s if cls[:level]
          h['x-legion-contains-phi']   = cls[:contains_phi].to_s unless cls[:contains_phi].nil?
          h['x-legion-jurisdictions']  = Array(cls[:jurisdictions]).join(',') if cls[:jurisdictions]
          h
        end

        def caller_headers
          caller_info = @options.dig(:caller, :requested_by) || {}
          h = {}
          h['x-legion-caller-identity'] = caller_info[:identity].to_s if caller_info[:identity]
          h['x-legion-caller-type']     = caller_info[:type].to_s     if caller_info[:type]
          h
        end

        def retention_headers
          cls = @options[:classification] || {}
          h = {}
          h['x-legion-retention'] = cls[:retention].to_s if cls[:retention]
          h
        end

        def tier_header
          h = {}
          h['x-legion-llm-tier'] = @options[:tier].to_s if @options[:tier]
          h
        end
      end
    end
  end
end
