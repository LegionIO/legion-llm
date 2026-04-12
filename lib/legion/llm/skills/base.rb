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

        def run(from_step: 0, context: {})
          inject_parts   = []
          total_duration = 0
          classification = context[:classification]
          conv_id        = context[:conversation_id]
          self_key       = "#{self.class.namespace}:#{self.class.skill_name}"

          Legion::Events.emit('skill.started', {
            conversation_id: conv_id,
            skill_name:      self.class.skill_name,
            namespace:       self.class.namespace,
            total_steps:     self.class.steps.length
          }) if conv_id

          self.class.steps[from_step..].each_with_index do |method_name, offset|
            step_idx = from_step + offset

            if conv_id && Legion::LLM::ConversationStore.skill_cancelled?(conv_id)
              Legion::LLM::ConversationStore.clear_cancel_flag(conv_id)
              return SkillRunResult.build(inject: inject_parts.join("\n\n"), gated: false,
                                         gate: nil, resume_at: nil, complete: false)
            end

            Legion::Events.emit('skill.step.started', {
              conversation_id: conv_id, step_name: method_name, step_index: step_idx
            }) if conv_id
            Legion::LLM::Metering.emit(
              request_type: 'skill.step.start', skill_name: self.class.skill_name,
              namespace: self.class.namespace, step_name: method_name,
              step_index: step_idx, tier: 'local'
            )

            t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

            begin
              result      = public_send(method_name, context: context)
              duration_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - t0) * 1000).round
            rescue StandardError => e
              duration_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - t0) * 1000).round
              Legion::LLM::ConversationStore.clear_skill_state(conv_id) if conv_id
              Legion::Events.emit('skill.step.failed', {
                conversation_id: conv_id, step_name: method_name, error: e.message
              }) if conv_id
              Legion::LLM::Audit.emit_skill(
                skill_name: self.class.skill_name, namespace: self.class.namespace,
                step_name: method_name, gate: nil, status: :failed,
                duration_ms: duration_ms, metadata: { error: e.message },
                classification: classification
              )
              Legion::LLM::Metering.emit(
                request_type: 'skill.step', skill_name: self.class.skill_name,
                namespace: self.class.namespace, step_name: method_name,
                step_index: step_idx, duration_ms: duration_ms, gate: nil, tier: 'local'
              )
              raise Legion::LLM::Skills::StepError.new(
                "#{self.class.skill_name}##{method_name} failed: #{e.message}", cause: e
              )
            end

            total_duration += duration_ms
            inject_parts << result.inject if result.inject

            Legion::Events.emit('skill.step.completed', {
              conversation_id: conv_id, step_name: method_name,
              duration_ms: duration_ms, metadata: result.metadata
            }) if conv_id
            Legion::LLM::Audit.emit_skill(
              skill_name: self.class.skill_name, namespace: self.class.namespace,
              step_name: method_name, gate: result.gate,
              status: :completed, duration_ms: duration_ms,
              metadata: result.metadata, classification: classification
            )
            Legion::LLM::Metering.emit(
              request_type: 'skill.step', skill_name: self.class.skill_name,
              namespace: self.class.namespace, step_name: method_name,
              step_index: step_idx, duration_ms: duration_ms, gate: result.gate&.to_s, tier: 'local'
            )

            if result.gate
              Legion::LLM::ConversationStore.set_skill_state(conv_id,
                                                             skill_key: self_key, resume_at: step_idx + 1) if conv_id
              Legion::Events.emit('skill.step.gated', {
                conversation_id: conv_id, step_name: method_name, gate_type: result.gate
              }) if conv_id
              return SkillRunResult.build(
                inject: inject_parts.join("\n\n"), gated: true,
                gate: result.gate, resume_at: step_idx + 1, complete: false
              )
            end
          end

          # Resolve chain class FIRST — no ghost transitions
          chain_next     = Legion::LLM::Skills::Registry.chain_for(self_key)
          chained_class  = chain_next ? Legion::LLM::Skills::Registry.find(chain_next) : nil
          resolved_chain = chained_class ? chain_next : nil

          Legion::LLM::ConversationStore.clear_skill_state(conv_id) if conv_id
          Legion::Events.emit('skill.completed', {
            conversation_id:   conv_id,
            skill_name:        self.class.skill_name,
            namespace:         self.class.namespace,
            total_duration_ms: total_duration,
            chained_to:        resolved_chain
          }) if conv_id

          if chained_class
            Legion::Events.emit('skill.chained', {
              conversation_id: conv_id, from_skill: self_key, to_skill: resolved_chain
            }) if conv_id
            chained_result = chained_class.new.run(from_step: 0, context: context)
            inject_parts << chained_result.inject if chained_result.inject
            return SkillRunResult.build(
              inject:    inject_parts.join("\n\n"),
              gated:     chained_result.gated,
              gate:      chained_result.gate,
              resume_at: chained_result.resume_at,
              complete:  chained_result.complete
            )
          end

          SkillRunResult.build(inject: inject_parts.join("\n\n"), gated: false,
                               gate: nil, resume_at: nil, complete: true)
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
