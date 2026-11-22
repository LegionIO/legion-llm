# frozen_string_literal: true

module ToolRegistryExamples
  def register_tool_entries(entries)
    entries.map do |entry|
      Legion::Settings::Extensions.register_tool(entry.fetch(:name), entry.except(:name))
    end
  end
end

RSpec.configure do |config|
  config.include ToolRegistryExamples, tool_registry: true
  config.before(:each, tool_registry: true) { Legion::Settings::Extensions.reset! }
  config.after(:each, tool_registry: true) { Legion::Settings::Extensions.reset! }
end
