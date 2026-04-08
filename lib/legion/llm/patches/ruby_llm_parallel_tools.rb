# frozen_string_literal: true

# Patch: RubyLLM::Chat parallel tool call execution
#
# RubyLLM's default `handle_tool_calls` iterates tool calls serially with
# `.each_value`, meaning when an LLM returns N tool calls in a single response
# they execute one-at-a-time. This patch replaces that loop with concurrent
# thread execution so all tool calls in a batch run in parallel, and results
# are collected before re-prompting the model.
#
# Additionally, RubyLLM fires `on_tool_result` with the raw tool return value
# (a String/Hash/etc.) which carries no `tool_call_id`. The legion-interlink
# bridge script's `serialize_tool_result` needs a `tool_call_id` field to
# match results back to the correct tool call slot in the UI — without it
# every result falls back to name-based matching, which breaks when multiple
# tools of the same name run in parallel and leaves them stuck on RUNNING.
#
# Fix: wrap each result in a ToolResultWrapper that exposes both the raw
# content/result AND the originating tool_call_id / id fields.
#
# NOTE: This is a temporary shim. When RubyLLM is replaced this file goes away.
#
# Thread safety notes:
#   - Each tool call executes in its own thread.
#   - @on[:tool_call] fires per-thread (fast, just event emission — safe).
#   - @on[:tool_result] fires per-thread with the wrapper object.
#   - add_message is called serially after all threads complete to preserve
#     message ordering and avoid races on @messages.
#   - If ANY tool returns a RubyLLM::Tool::Halt, complete() is skipped —
#     matching the original semantics.

module Legion
  module LLM
    module Patches
      # Wraps a raw tool result value so that the bridge-script's
      # serialize_tool_result can read both :tool_call_id/:id (for UI matching)
      # and :result/:content (for the result payload) off a single object.
      ToolResultWrapper = Struct.new(:result, :content, :tool_call_id, :id, :tool_name) do
        # Delegate is_a? checks for RubyLLM::Tool::Halt so the caller can still
        # detect halt results transparently.
        def is_a?(klass)
          result.is_a?(klass) || super
        end

        alias_method :kind_of?, :is_a?
      end

      module RubyLLMParallelTools
        def handle_tool_calls(response, &)
          tool_calls = response.tool_calls.values

          # Dispatch all tool calls concurrently, preserving original order.
          threads = tool_calls.map do |tool_call|
            Thread.new do
              @on[:new_message]&.call
              @on[:tool_call]&.call(tool_call)
              raw = execute_tool(tool_call)
              # Wrap so serialize_tool_result in the bridge script gets an ID.
              wrapper = ToolResultWrapper.new(
                raw,                  # :result  — raw value (String/Hash/Halt/etc.)
                raw,                  # :content — alias for bridge compat
                tool_call.id,         # :tool_call_id
                tool_call.id,         # :id
                tool_call.name        # :tool_name
              )
              @on[:tool_result]&.call(wrapper)
              { tool_call: tool_call, raw: raw }
            end
          end

          results = threads.map(&:value) # block until all complete

          # Commit messages serially — preserves ordering, avoids @messages races.
          halt_result = nil
          results.each do |entry|
            tool_call    = entry[:tool_call]
            raw          = entry[:raw]
            tool_payload = raw.is_a?(RubyLLM::Tool::Halt) ? raw.content : raw
            content      = content_like?(tool_payload) ? tool_payload : tool_payload.to_s
            message      = add_message(role: :tool, content: content, tool_call_id: tool_call.id)
            @on[:end_message]&.call(message)
            halt_result = raw if raw.is_a?(RubyLLM::Tool::Halt)
          end

          reset_tool_choice if forced_tool_choice?
          halt_result || complete(&)
        end
      end
    end
  end
end

# Use prepend (not alias_method/override) so the patch stays clearly visible
# in the ancestor chain and is easy to remove when RubyLLM is dropped.
RubyLLM::Chat.prepend(Legion::LLM::Patches::RubyLLMParallelTools)
