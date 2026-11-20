# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/settings/extensions'

module Legion
  module LLM
    module Inference
      module RegistryTools
        include Legion::Logging::Helper

        private

        # A request-local view of the framework-owned registry, shared by the
        # executor's steps. New requests read fresh entries; MCP discovery
        # invalidates the view because it can publish tools even on failure. Nested
        # metadata is owned by the registry and must not be mutated or frozen here.
        def registry_tool_snapshot
          @registry_tool_snapshot ||= begin
            entries = Legion::Settings::Extensions.tools
            always = Legion::Settings::Extensions::Filter.apply_tool_filters(entries, { deferred: false }).freeze
            deferred = Legion::Settings::Extensions::Filter.apply_tool_filters(entries, { deferred: true }).freeze
            {
              entries:       entries,
              by_name:       entries.to_h { |entry| [entry.fetch(:name), entry] }.freeze,
              always_loaded: always,
              deferred:      deferred,
              always_names:  always.to_set { |entry| entry.fetch(:name) }.freeze
            }.freeze
          end
        end
      end
    end
  end
end
