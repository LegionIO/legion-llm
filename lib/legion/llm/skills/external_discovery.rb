# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Skills
      module ExternalDiscovery
        extend Legion::Logging::Helper

        module_function

        def discover
          dirs = []
          dirs.concat(claude_directories) if claude_auto_discover?
          dirs.concat(codex_directories)  if codex_auto_discover?
          dirs
        end

        def claude_directories
          dirs = []

          skills_dir = ::File.expand_path(Legion::Settings[:llm][:skills][:discovery_roots][:claude_skills])
          dirs << skills_dir if ::File.directory?(skills_dir)

          plugins_dir = ::File.expand_path(Legion::Settings[:llm][:skills][:discovery_roots][:claude_plugins])
          if ::File.directory?(plugins_dir)
            ::Dir.glob(::File.join(plugins_dir, '*', 'skills')).each do |skill_subdir|
              dirs << skill_subdir if ::File.directory?(skill_subdir)
            end
          end

          dirs.uniq
        end

        def codex_directories
          candidate = ::File.expand_path(Legion::Settings[:llm][:skills][:discovery_roots][:codex_skills])
          ::File.directory?(candidate) ? [candidate] : []
        end

        def claude_auto_discover?
          Legion::Settings[:llm][:skills][:auto_discover][:claude] == true
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.skills.external_discovery.claude_auto_discover')
          false
        end

        def codex_auto_discover?
          Legion::Settings[:llm][:skills][:auto_discover][:codex] == true
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.skills.external_discovery.codex_auto_discover')
          false
        end
      end
    end
  end
end
