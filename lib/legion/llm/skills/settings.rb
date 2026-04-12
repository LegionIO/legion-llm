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
          auto_discover:     { claude: true, codex: true },
          enabled_skills:    [],
          disabled_skills:   []
        }.freeze

        module_function

        def apply
          return unless defined?(Legion::Settings)

          llm_settings = (Legion::Settings[:llm] || {}).dup
          current = llm_settings[:skills] || {}
          merged  = deep_merge(DEFAULTS, current)
          llm_settings[:skills] = merged
          Legion::Settings[:llm] = llm_settings
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
