# frozen_string_literal: true

module Legion
  module LLM
    module Types
      TOOL_NAME_MAX_LENGTH = 64
      ToolDefinition = ::Data.define(:name, :description, :parameters, :source) do
        def self.build(name:, description: '', parameters: nil, source: nil)
          new(
            sanitize_tool_name(name),
            description.to_s,
            parameters || {},
            source || { type: :builtin }
          )
        end

        def self.from_hash(hash, source: nil)
          normalized = hash.respond_to?(:transform_keys) ? hash.transform_keys(&:to_sym) : {}
          build(
            name:        normalized[:name],
            description: normalized[:description],
            parameters:  normalized[:parameters] || normalized[:input_schema],
            source:      source || normalized[:source]
          )
        end

        def self.from_tool_class(tool_class, source: nil)
          raw_name = tool_class.respond_to?(:tool_name) ? tool_class.tool_name : tool_class.name.to_s
          build(
            name:        raw_name,
            description: tool_class.respond_to?(:description) ? tool_class.description : '',
            parameters:  tool_class.respond_to?(:input_schema) ? tool_class.input_schema : {},
            source:      source || { type: :registry, tool_class: tool_class }
          )
        end

        def self.from_registry_entry(entry)
          build(
            name:        entry[:name],
            description: entry[:description],
            parameters:  entry[:input_schema] || entry[:parameters],
            source:      {
              type:       :registry,
              tool_class: entry[:tool_class],
              extension:  entry[:extension],
              runner:     entry[:runner]
            }.compact
          )
        end

        def self.sanitize_tool_name(raw)
          name = raw.to_s.tr('.', '_')
          name = name.gsub(/[^a-zA-Z0-9_-]/, '')
          name = name[0, TOOL_NAME_MAX_LENGTH] if name.length > TOOL_NAME_MAX_LENGTH
          name.empty? ? 'tool' : name
        end

        def to_h
          {
            name:        name,
            description: description,
            parameters:  parameters
          }.compact
        end
      end
    end
  end
end
