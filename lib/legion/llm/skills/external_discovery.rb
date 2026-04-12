# frozen_string_literal: true

module Legion
  module LLM
    module Skills
      module ExternalDiscovery
        module_function

        def discover
          dirs = []
          dirs.concat(claude_directories) if claude_auto_discover?
          dirs.concat(codex_directories)  if codex_auto_discover?
          dirs
        end

        def claude_directories
          home = ::File.expand_path('~')
          dirs = []

          skills_dir = ::File.join(home, '.claude', 'skills')
          dirs << skills_dir if ::File.directory?(skills_dir)

          plugins_dir = ::File.join(home, '.claude', 'plugins')
          if ::File.directory?(plugins_dir)
            ::Dir.glob(::File.join(plugins_dir, '*', 'skills')).each do |skill_subdir|
              dirs << skill_subdir if ::File.directory?(skill_subdir)
            end
          end

          dirs.uniq
        end

        def codex_directories
          candidate = ::File.join(::File.expand_path('~'), '.codex', 'skills')
          ::File.directory?(candidate) ? [candidate] : []
        end

        def claude_auto_discover?
          Legion::LLM.settings.dig(:skills, :auto_discover, :claude) != false
        rescue StandardError
          true
        end

        def codex_auto_discover?
          Legion::LLM.settings.dig(:skills, :auto_discover, :codex) != false
        rescue StandardError
          true
        end
      end
    end
  end
end
