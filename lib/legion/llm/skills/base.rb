# frozen_string_literal: true

require_relative 'step_result'
require_relative 'skill_run_result'
require_relative 'errors'

module Legion
  module LLM
    module Skills
      class Base
        class << self
          def skill_name(name = nil)
            name ? (@skill_name = name.to_s) : @skill_name
          end

          def description(text = nil)
            text ? (@description = text) : @description
          end

          def trigger(type = nil)
            type ? (@trigger = type) : (@trigger || :on_demand)
          end

          def namespace(ns = nil)
            ns ? (@namespace = ns.to_s) : @namespace
          end

          def steps(*names)
            if names.any?
              @steps = names
              validate_steps!
            else
              @steps || []
            end
          end

          def trigger_words(*words)
            words.any? ? (@trigger_words_list = words.map(&:to_s)) : (@trigger_words_list || [])
          end

          def file_change_triggers(*patterns)
            patterns.any? ? (@file_change_trigger_patterns = patterns.map(&:to_s)) : (@file_change_trigger_patterns || [])
          end

          def file_change_trigger_patterns
            @file_change_trigger_patterns || []
          end

          def follows(skill_key = nil)
            skill_key ? (@follows_skill = skill_key.to_s) : @follows_skill
          end

          def follows_skill
            @follows_skill
          end

          # `condition` is used instead of `when` because `when` is a Ruby reserved keyword.
          # DSL: `condition classification: { level: 'internal' }`
          def condition(**conds)
            @when_conditions = conds
          end

          def when_conditions
            @when_conditions || {}
          end

          def content(context: {}) # rubocop:disable Lint/UnusedMethodArgument
            path = content_path
            return ::File.read(path) if path && ::File.exist?(path)

            generate_content_from_step_names
          end

          private

          def validate_steps!
            missing = @steps.reject { |name| method_defined?(name) || private_method_defined?(name) }
            return if missing.empty?

            raise InvalidSkill, "#{self}: missing step methods: #{missing.join(', ')}"
          end

          def content_path
            return nil unless @skill_name

            # Derive gem name: Legion::Extensions::SkillSuperpowers -> lex-skill-superpowers
            parts = name.to_s.split('::').drop(2)
            return nil if parts.empty?

            gem_name = parts.first.gsub(/([A-Z])/) { "-#{::Regexp.last_match(1).downcase}" }.sub(/^-/, 'lex-')
            spec = begin
              ::Gem::Specification.find_by_name(gem_name)
            rescue ::Gem::MissingSpecError
              nil
            end
            return nil unless spec

            ::File.join(spec.gem_dir, 'content', @skill_name, 'SKILL.md')
          end

          def generate_content_from_step_names
            lines = ["# #{@skill_name} — #{@skill_name.to_s.tr('-', ' ').capitalize}", '',
                     @description.to_s, '', '## Steps', '']
            (@steps || []).each_with_index { |n, i| lines << "#{i + 1}. #{n.to_s.tr('_', ' ').capitalize}" }
            lines.join("\n")
          end
        end

        protected

        def detect_project(context)
          root = context[:project_root]
          return 'unknown project' unless root

          ::File.basename(root.to_s)
        end

        def conversation_id(context)
          context[:conversation_id]
        end

        def current_intent(context)
          context[:intent]
        end
      end
    end
  end
end
