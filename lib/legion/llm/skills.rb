# frozen_string_literal: true

require_relative 'skills/errors'
require_relative 'skills/step_result'
require_relative 'skills/skill_run_result'
require_relative 'skills/registry'
require_relative 'skills/settings'
require_relative 'skills/base'
require_relative 'skills/disk_loader'
require_relative 'skills/external_discovery'

module Legion
  module LLM
    module Skills
      module_function

      def start
        Settings.apply
        directories = settings_directories + ExternalDiscovery.discover
        DiskLoader.load_from_directories(directories)
      end

      def settings_directories
        Array(Legion::LLM.settings.dig(:skills, :directories) || [])
      rescue StandardError
        []
      end
    end
  end
end
