# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module SkillInjector
          include Legion::Logging::Helper
          include Steps::Logging

          def step_skill_injector
            unless skills_enabled?
              log_step_debug(:skill_injector, :skipped, reason: :disabled_or_unavailable)
              return
            end

            conv_id = @request.conversation_id
            unless conv_id
              log_step_debug(:skill_injector, :skipped, reason: :no_conversation_id)
              return
            end
            log_step_debug(:skill_injector, :start)

            if (state = Inference::Conversation.skill_state(conv_id))
              log_step_debug(:skill_injector, :resume_active_skill, skill_key: state[:skill_key], resume_at: state[:resume_at])
              resume_active_skill(conv_id, state)
              return
            end

            @skill_executed = false

            check_trigger_words(conv_id)
            return if @skill_executed

            check_file_change_triggers(conv_id)
            return if @skill_executed

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
              Legion::Settings[:llm][:skills][:enabled] != false
          end

          def resume_active_skill(conv_id, state)
            skill_class = Legion::LLM::Skills::Registry.find(state[:skill_key])
            unless skill_class
              log_step_info(:skill_injector, :clear_missing_skill_state, skill_key: state[:skill_key])
              Inference::Conversation.clear_skill_state(conv_id)
              return
            end

            result = skill_class.new.run(from_step: state[:resume_at],
                                         context:   build_skill_context(conv_id))
            inject_skill_result(result)
          end

          def check_trigger_words(conv_id)
            if at_max_active_skills?(conv_id)
              log_step_debug(:skill_injector, :trigger_words_skipped, reason: :max_active_skills)
              return
            end

            text  = extract_message_text
            words = text.downcase.gsub(/[^a-z ]/, ' ').split.to_set
            if words.empty?
              log_step_debug(:skill_injector, :trigger_words_skipped, reason: :no_words)
              return
            end

            index = Legion::LLM::Skills::Registry.trigger_word_index
            matched_keys = words.flat_map { |w| index[w] || [] }.uniq
            if matched_keys.empty?
              log_step_debug(:skill_injector, :trigger_words_no_match, word_count: words.size)
              return
            end
            log_step_debug(:skill_injector, :trigger_words_matched, matched_count: matched_keys.size)

            matched_keys.each do |key|
              skill_class = Legion::LLM::Skills::Registry.find(key)
              next unless skill_class
              next if skill_disabled?(key)

              activate_skill(conv_id, skill_class)
              break
            end
          end

          def check_file_change_triggers(conv_id)
            if at_max_active_skills?(conv_id)
              log_step_debug(:skill_injector, :file_triggers_skipped, reason: :max_active_skills)
              return
            end

            changed = Array(@request.metadata&.dig(:changed_files) || [])
            if changed.empty?
              log_step_debug(:skill_injector, :file_triggers_skipped, reason: :no_changed_files)
              return
            end
            log_step_debug(:skill_injector, :file_triggers_scan, changed_file_count: changed.size)

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
            if at_max_active_skills?(conv_id)
              log_step_debug(:skill_injector, :auto_skills_skipped, reason: :max_active_skills)
              return
            end
            if Legion::Settings[:llm][:skills][:auto_inject] == false
              log_step_debug(:skill_injector, :auto_skills_skipped, reason: :disabled)
              return
            end

            candidates = Legion::LLM::Skills::Registry.by_trigger(:auto)
            log_step_debug(:skill_injector, :auto_skills_scan, candidate_count: candidates.size)
            candidates.each do |skill_class|
              key = "#{skill_class.namespace}:#{skill_class.skill_name}"
              next if skill_disabled?(key)
              next unless when_conditions_match?(skill_class)

              activate_skill(conv_id, skill_class)
              break
            end
          end

          def activate_skill(conv_id, skill_class)
            skill_key = "#{skill_class.namespace}:#{skill_class.skill_name}"
            log_step_info(
              :skill_injector,
              :activate_skill,
              skill: skill_key
            )
            result = skill_class.new.run(from_step: 0, context: build_skill_context(conv_id))
            @skill_executed = true
            log_step_info(:skill_injector, :skill_executed, skill: skill_key, has_inject: !(result.inject.nil? || result.inject.empty?))
            inject_skill_result(result)
          end

          def inject_skill_result(result)
            unless result.inject && !result.inject.empty?
              log_step_debug(:skill_injector, :inject_skipped, reason: :empty_result)
              return
            end

            @enrichments['skill:active'] = result.inject
            log_step_debug(:skill_injector, :inject_enrichment, key_count: result.inject.respond_to?(:keys) ? result.inject.keys.size : nil)
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

            missing = Object.new
            expected.all? do |k, v|
              actual.is_a?(Hash) &&
                (actual_value = actual[k.to_sym] || actual[k.to_s] || missing) != missing &&
                deep_subset_match?(actual_value, v)
            end
          end

          def at_max_active_skills?(conv_id)
            max    = Legion::Settings[:llm][:skills][:max_active_skills]
            active = Inference::Conversation.skill_state(conv_id) ? 1 : 0
            active >= max
          end

          def skill_disabled?(key)
            disabled = Array(Legion::Settings[:llm][:skills][:disabled_skills])
            enabled  = Array(Legion::Settings[:llm][:skills][:enabled_skills])
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
