# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module SkillInjector
          include Legion::Logging::Helper

          def step_skill_injector
            return unless skills_enabled?

            conv_id = @request.conversation_id
            return unless conv_id

            if (state = ConversationStore.skill_state(conv_id))
              resume_active_skill(conv_id, state)
              return
            end

            check_trigger_words(conv_id)
            return if @enrichments.key?('skill:active')

            check_file_change_triggers(conv_id)
            return if @enrichments.key?('skill:active')

            check_auto_skills(conv_id)
          rescue StandardError => e
            @warnings << "SkillInjector error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.skill_injector')
          end

          private

          def skills_enabled?
            defined?(Legion::LLM::Skills::Registry) &&
              defined?(Legion::LLM) &&
              Legion::LLM.respond_to?(:settings) &&
              Legion::LLM.settings.dig(:skills, :enabled) != false
          end

          def resume_active_skill(conv_id, state)
            skill_class = Legion::LLM::Skills::Registry.find(state[:skill_key])
            unless skill_class
              ConversationStore.clear_skill_state(conv_id)
              return
            end

            result = skill_class.new.run(from_step: state[:resume_at],
                                         context:   build_skill_context(conv_id))
            inject_skill_result(result)
          end

          def check_trigger_words(conv_id)
            return if at_max_active_skills?(conv_id)

            text  = extract_message_text
            words = text.downcase.gsub(/[^a-z ]/, ' ').split.to_set
            return if words.empty?

            index = Legion::LLM::Skills::Registry.trigger_word_index
            matched_keys = words.flat_map { |w| index[w] || [] }.uniq
            return if matched_keys.empty?

            matched_keys.each do |key|
              skill_class = Legion::LLM::Skills::Registry.find(key)
              next unless skill_class
              next if skill_disabled?(key)

              activate_skill(conv_id, skill_class)
              break
            end
          end

          def check_file_change_triggers(conv_id)
            return if at_max_active_skills?(conv_id)

            changed = Array(@request.metadata&.dig(:changed_files) || [])
            return if changed.empty?

            Legion::LLM::Skills::Registry.file_trigger_skills.each do |skill_class|
              key = "#{skill_class.namespace}:#{skill_class.skill_name}"
              next if skill_disabled?(key)

              matched = changed.any? do |path|
                skill_class.file_change_trigger_patterns.any? do |pat|
                  ::File.fnmatch(pat, path, ::File::FNM_DOTMATCH)
                end
              end
              next unless matched

              activate_skill(conv_id, skill_class)
              break
            end
          end

          def check_auto_skills(conv_id)
            return if at_max_active_skills?(conv_id)
            return if Legion::LLM.settings.dig(:skills, :auto_inject) == false

            Legion::LLM::Skills::Registry.by_trigger(:auto).each do |skill_class|
              key = "#{skill_class.namespace}:#{skill_class.skill_name}"
              next if skill_disabled?(key)
              next unless when_conditions_match?(skill_class)

              activate_skill(conv_id, skill_class)
              break
            end
          end

          def activate_skill(conv_id, skill_class)
            result = skill_class.new.run(from_step: 0, context: build_skill_context(conv_id))
            inject_skill_result(result)
          end

          def inject_skill_result(result)
            return unless result.inject && !result.inject.empty?

            @enrichments['skill:active'] = result.inject
          end

          def when_conditions_match?(skill_class)
            return true if skill_class.when_conditions.empty?

            skill_class.when_conditions.all? do |key, expected|
              unless @request.respond_to?(key)
                log.warn("[skill_injector] unknown condition key #{key.inspect}, non-matching")
                next false
              end

              deep_subset_match?(@request.public_send(key), expected)
            end
          end

          def deep_subset_match?(actual, expected)
            return actual == expected unless expected.is_a?(Hash)

            expected.all? do |k, v|
              actual.is_a?(Hash) && actual.key?(k) && deep_subset_match?(actual[k], v)
            end
          end

          def at_max_active_skills?(conv_id)
            max    = Legion::LLM.settings.dig(:skills, :max_active_skills) || 1
            active = ConversationStore.skill_state(conv_id) ? 1 : 0
            active >= max
          end

          def skill_disabled?(key)
            disabled = Array(Legion::LLM.settings.dig(:skills, :disabled_skills) || [])
            enabled  = Array(Legion::LLM.settings.dig(:skills, :enabled_skills)  || [])
            return true if disabled.include?(key)
            return false if enabled.empty?

            !enabled.include?(key)
          end

          def extract_message_text
            @request.messages.last(2).map do |msg|
              msg.is_a?(Hash) ? (msg[:content] || msg['content'] || '').to_s : msg.to_s
            end.join(' ')
          end

          def build_skill_context(conv_id)
            {
              conversation_id: conv_id,
              classification:  @request.classification,
              metadata:        @request.metadata,
              intent:          @request.extra&.dig(:intent)
            }
          end
        end
      end
    end
  end
end
