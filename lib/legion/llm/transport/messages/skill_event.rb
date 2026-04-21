# frozen_string_literal: true

require_relative '../message'

module Legion
  module LLM
    module Audit
      class SkillEvent < Legion::LLM::Transport::Message
        def type        = 'llm.audit.skill'
        def exchange    = Legion::LLM::Transport::Exchanges::Audit
        def routing_key = "audit.skill.#{@options[:namespace]}.#{@options[:skill_name]}"
        def priority    = 0
        def encrypt?    = true
        def expiration  = nil

        def headers
          super.merge(skill_headers).merge(classification_headers)
        end

        private

        def message_id_prefix = 'audit_skill'

        def skill_headers
          h = {}
          h['x-legion-skill-name']      = @options[:skill_name].to_s if @options[:skill_name]
          h['x-legion-skill-namespace'] = @options[:namespace].to_s  if @options[:namespace]
          h['x-legion-skill-step']      = @options[:step_name].to_s  if @options[:step_name]
          h['x-legion-skill-gate']      = @options[:gate].to_s       if @options[:gate]
          h['x-legion-skill-status']    = @options[:status].to_s     if @options[:status]
          h
        end

        def classification_headers
          cls = @options[:classification] || {}
          h = {}
          h['x-legion-classification'] = cls[:level].to_s        if cls[:level]
          h['x-legion-contains-phi']   = cls[:contains_phi].to_s unless cls[:contains_phi].nil?
          h
        end
      end
    end
  end
end
