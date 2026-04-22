# frozen_string_literal: true

# Backwards-compatibility shim — the implementation moved to tool_adapter.rb.
# Callers that require this path directly will still find McpToolAdapter via the alias.
require_relative 'tool_adapter'
