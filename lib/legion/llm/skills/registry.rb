# frozen_string_literal: true

require 'set'
require 'legion/logging/helper'

module Legion
  module LLM
    module Skills
      module Registry
        extend Legion::Logging::Helper

        MUTEX = Mutex.new

        class << self
          def register(skill_class)
            validate!(skill_class)
            MUTEX.synchronize do
              key = registry_key(skill_class)
              if (@by_key ||= {}).key?(key)
                log.warn("[skills][registry] duplicate: #{key} replaced")
              end
              @ordered ||= []
              @ordered.reject! { |k| k == key }
              @by_key[key] = skill_class
              @ordered << key
              index_trigger_words(key, skill_class)
              index_file_triggers(skill_class)
              index_chain(skill_class)
            end
          end

          def all
            MUTEX.synchronize { (@ordered || []).filter_map { |k| (@by_key || {})[k] } }
          end

          def find(key)
            MUTEX.synchronize { (@by_key || {})[key] }
          end

          def by_trigger(type)
            all.select { |c| c.trigger == type }
          end

          def chain_for(skill_key)
            MUTEX.synchronize { (@chain_index || {})[skill_key] }
          end

          def trigger_word_index
            MUTEX.synchronize { (@trigger_word_index || {}).dup }
          end

          def file_trigger_skills
            MUTEX.synchronize { (@file_trigger_skills || []).dup }
          end

          def reset!
            MUTEX.synchronize do
              @by_key              = {}
              @ordered             = []
              @chain_index         = {}
              @trigger_word_index  = {}
              @file_trigger_skills = []
            end
          end

          private

          def registry_key(skill_class)
            "#{skill_class.namespace}:#{skill_class.skill_name}"
          end

          def validate!(skill_class)
            raise InvalidSkill, "#{skill_class}: skill_name required" if skill_class.skill_name.nil?
            raise InvalidSkill, "#{skill_class}: namespace required"  if skill_class.namespace.nil?

            check_chain_cycle!(skill_class)
          end

          def check_chain_cycle!(skill_class)
            return unless skill_class.follows_skill

            self_key = registry_key(skill_class)
            visited  = Set.new([self_key])
            current  = skill_class.follows_skill
            while current
              raise InvalidSkill, "Cycle detected in skill chain involving #{self_key}" if visited.include?(current)

              visited.add(current)
              current = (@by_key || {})[current]&.follows_skill
            end
          end

          def index_trigger_words(key, skill_class)
            @trigger_word_index ||= {}
            skill_class.trigger_words.each do |word|
              @trigger_word_index[word] ||= []
              @trigger_word_index[word] << key unless @trigger_word_index[word].include?(key)
            end
          end

          def index_file_triggers(skill_class)
            @file_trigger_skills ||= []
            return if skill_class.file_change_trigger_patterns.empty?
            return if @file_trigger_skills.include?(skill_class)

            @file_trigger_skills << skill_class
          end

          def index_chain(skill_class)
            @chain_index ||= {}
            return unless skill_class.follows_skill

            self_key = registry_key(skill_class)
            @chain_index[skill_class.follows_skill] = self_key
          end
        end
      end
    end
  end
end
