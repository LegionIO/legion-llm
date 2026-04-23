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

          def namespace(nsp = nil)
            nsp ? (@namespace = nsp.to_s) : @namespace
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

          attr_reader :follows_skill

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

          emit_event(conv_id, 'skill.started',
                     skill_name: self.class.skill_name, namespace: self.class.namespace,
                     total_steps: self.class.steps.length)

          remaining_steps = self.class.steps[from_step..] || []

          remaining_steps.each_with_index do |method_name, offset|
            step_idx = from_step + offset
            if conv_id && Legion::LLM::Inference::Conversation.skill_cancelled?(conv_id)
              Legion::LLM::Inference::Conversation.clear_cancel_flag(conv_id)
              return SkillRunResult.build(inject: inject_parts.join("\n\n"),
                                          gated: false, gate: nil, resume_at: nil, complete: false)
            end

            result, duration_ms = execute_step(method_name, step_idx, context, conv_id, classification)
            total_duration += duration_ms
            inject_parts << result.inject if result.inject

            emit_step_success(conv_id, method_name, step_idx, duration_ms, result, classification)

            next unless result.gate

            if conv_id
              Legion::LLM::Inference::Conversation.set_skill_state(
                conv_id, skill_key: self_key, resume_at: step_idx + 1
              )
            end
            emit_event(conv_id, 'skill.step.gated',
                       step_name: method_name, gate_type: result.gate)
            return SkillRunResult.build(
              inject: inject_parts.join("\n\n"), gated: true,
              gate: result.gate, resume_at: step_idx + 1, complete: false
            )
          end

          finalize_run(conv_id, self_key, inject_parts, total_duration, context)
        end

        private

        def execute_step(method_name, step_idx, context, conv_id, classification)
          t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          emit_event(conv_id, 'skill.step.started',
                     step_name: method_name, step_index: step_idx)
          Legion::LLM::Metering.emit(
            request_type: 'skill.step.start', skill_name: self.class.skill_name,
            namespace: self.class.namespace, step_name: method_name,
            step_index: step_idx, tier: 'local'
          )
          result = public_send(method_name, context: context)
          unless result.respond_to?(:inject) && result.respond_to?(:metadata) && result.respond_to?(:gate)
            raise Legion::LLM::Skills::StepError.new(
              "#{self.class.skill_name}##{method_name} returned #{result.class} instead of StepResult",
              cause: nil
            )
          end

          duration_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - t0) * 1000).round
          [result, duration_ms]
        rescue StandardError => e
          duration_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - t0) * 1000).round
          handle_step_error(e, method_name, step_idx, conv_id, duration_ms, classification)
        end

        def handle_step_error(err, method_name, step_idx, conv_id, duration_ms, classification)
          Legion::LLM::Inference::Conversation.clear_skill_state(conv_id) if conv_id
          emit_event(conv_id, 'skill.step.failed',
                     step_name: method_name, error: err.message)
          Legion::LLM::Audit.emit_skill(
            skill_name: self.class.skill_name, namespace: self.class.namespace,
            step_name: method_name, gate: nil, status: :failed,
            duration_ms: duration_ms, metadata: { error: err.message },
            classification: classification
          )
          Legion::LLM::Metering.emit(
            request_type: 'skill.step', skill_name: self.class.skill_name,
            namespace: self.class.namespace, step_name: method_name,
            step_index: step_idx, duration_ms: duration_ms, gate: nil, tier: 'local'
          )
          raise Legion::LLM::Skills::StepError.new(
            "#{self.class.skill_name}##{method_name} failed: #{err.message}", cause: err
          )
        end

        def emit_step_success(conv_id, method_name, step_idx, duration_ms, result, classification)
          emit_event(conv_id, 'skill.step.completed',
                     step_name: method_name, duration_ms: duration_ms,
                     metadata: result.metadata)
          Legion::LLM::Audit.emit_skill(
            skill_name: self.class.skill_name, namespace: self.class.namespace,
            step_name: method_name, gate: result.gate,
            status: :completed, duration_ms: duration_ms,
            metadata: result.metadata, classification: classification
          )
          Legion::LLM::Metering.emit(
            request_type: 'skill.step', skill_name: self.class.skill_name,
            namespace: self.class.namespace, step_name: method_name,
            step_index: step_idx, duration_ms: duration_ms,
            gate: result.gate&.to_s, tier: 'local'
          )
        end

        def finalize_run(conv_id, self_key, inject_parts, total_duration, context)
          chain_next    = Legion::LLM::Skills::Registry.chain_for(self_key)
          chained_class = chain_next ? Legion::LLM::Skills::Registry.find(chain_next) : nil
          resolved_chain = chained_class ? chain_next : nil

          Legion::LLM::Inference::Conversation.clear_skill_state(conv_id) if conv_id
          emit_event(conv_id, 'skill.completed',
                     skill_name: self.class.skill_name, namespace: self.class.namespace,
                     total_duration_ms: total_duration, chained_to: resolved_chain)

          return run_chained(chained_class, chain_next, conv_id, self_key, inject_parts, context) if chained_class

          SkillRunResult.build(inject: inject_parts.join("\n\n"),
                               gated: false, gate: nil, resume_at: nil, complete: true)
        end

        def run_chained(chained_class, chain_key, conv_id, self_key, inject_parts, context)
          emit_event(conv_id, 'skill.chained',
                     from_skill: self_key, to_skill: chain_key)
          chained_result = chained_class.new.run(from_step: 0, context: context)
          inject_parts << chained_result.inject if chained_result.inject
          SkillRunResult.build(
            inject:    inject_parts.join("\n\n"),
            gated:     chained_result.gated,
            gate:      chained_result.gate,
            resume_at: chained_result.resume_at,
            complete:  chained_result.complete
          )
        end

        def emit_event(conv_id, event, **payload)
          return unless conv_id

          Legion::Events.emit(event, conversation_id: conv_id, **payload)
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
