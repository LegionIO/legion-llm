# frozen_string_literal: true

module Legion
  module LLM
    module Skills
      module Settings
        DEFAULTS = {
          enabled:           true,
          auto_inject:       true,
          on_demand:         true,
          max_active_skills: 1,
          directories:       ['.legion/skills', '~/.legionio/skills'],
          auto_discover:     { claude: false, codex: false },
          enabled_skills:    [],
          disabled_skills:   []
        }.freeze

        module_function

        def apply
          current = Legion::Settings[:llm][:skills] || {}
          Legion::Settings[:llm][:skills] = deep_merge(DEFAULTS, current)
        end

        def deep_merge(base, override)
          result = base.dup
          override.each do |key, val|
            result[key] = val.is_a?(Hash) && result[key].is_a?(Hash) ? deep_merge(result[key], val) : val
          end
          result
        end
      end
    end
  end
end
