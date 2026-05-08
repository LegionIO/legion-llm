# frozen_string_literal: true

require_relative '../message'

module Legion
  module LLM
    module Transport
      module Messages
        class PromptEvent < Legion::LLM::Transport::Message
          def type        = 'llm.audit.prompt'
          def exchange    = Legion::LLM::Transport::Exchanges::Audit
          def routing_key = "audit.prompt.#{@options[:request_type]}"
          def priority    = 0
          def encrypt?    = Legion::LLM::Settings.value(:compliance, :encrypt_audit) == true
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
            caller_raw = @options[:caller] || {}
            return {} unless caller_raw.is_a?(Hash)

            caller_info = caller_raw[:requested_by] || caller_raw['requested_by'] || caller_raw
            caller_info = {} unless caller_info.is_a?(Hash)
            top_id      = @options[:identity] || {}
            top_id      = {} unless top_id.is_a?(Hash)
            extension   = caller_raw[:extension] || caller_raw['extension']
            type        = caller_info[:type] || caller_info['type'] || top_id[:type] || top_id['type'] ||
                          (extension && 'extension')
            h = {}
            h['x-legion-request-caller-type'] = type.to_s if type
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
end
