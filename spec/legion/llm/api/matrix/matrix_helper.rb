# frozen_string_literal: true

# Shared rig for the in-process matrix harness (G23). Boots the real Sinatra
# app with all client routes registered, registers the FakeProvider, pins
# default_provider/default_model so routing resolves to :fake, and exposes a
# tiny set of helpers each matrix spec uses.
#
# The harness is the commit gate: it runs the FULL client × scenario matrix
# in-process, catches the regressions live e2e catches days later, and runs
# in milliseconds because no provider HTTP/AMQP is involved.

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'

require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/namespaces/anthropic/messages'
require 'legion/llm/api/namespaces/openai/responses'
require 'legion/llm/api/namespaces/openai/chat/completions'
require 'legion/llm/api/debug_formats'

require_relative '../../../../support/fake_provider'

module MatrixHelper
  FAKE_MODEL = 'fake-default'

  # Tool class for the execution-proxy / server_tool_use scenario. Returns a
  # deterministic result that scenario fixtures expect to see surfaced as a
  # server_tool_use/server_tool_result block on the next turn.
  class FakeLegionEcho
    def self.tool_name = 'fake_legion_echo'
    def self.description = 'Echoes the value argument back. Test-only LegionIO tool.'

    def self.input_schema
      {
        type:       'object',
        properties: { value: { type: 'string' } },
        required:   %w[value]
      }
    end

    def self.call(**args)
      value = args[:value] || args['value']
      "echo:#{value}"
    end
  end

  class FakeLegionFailure
    def self.tool_name = 'fake_legion_failure'
    def self.description = 'Raises a deterministic test failure.'

    def self.input_schema
      {
        type:       'object',
        properties: {},
        required:   []
      }
    end

    def self.call(**)
      raise ArgumentError, 'deterministic fake LegionIO tool failure'
    end
  end

  module_function

  # Real Sinatra app with all three client-format routes mounted. Reused by
  # every matrix spec. Created once per spec via `let(:app) { MatrixHelper.app_class }`.
  def app_class
    @app_class ||= Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      set :show_exceptions, false
      set :raise_errors, false
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers
      namespace('/v1/messages') { register Legion::LLM::API::Namespaces::Anthropic::Messages }
      register Legion::LLM::API::Namespaces::OpenAI::Responses
      register Legion::LLM::API::Namespaces::OpenAI::Chat::Completions
    end
  end

  # Configure settings + registry to point routing at FakeProvider. Call from
  # `before(:each)` in every matrix spec.
  def configure_for_fake!
    Legion::Settings[:llm][:default_provider] = :fake
    Legion::Settings[:llm][:default_model] = FAKE_MODEL
    Legion::Settings[:llm][:pipeline_enabled] = true
    Legion::Settings[:llm][:pipeline_async_post_steps] = false
    Legion::Settings[:llm][:routing][:enabled] = false
    Legion::Settings[:llm][:routing][:escalation] ||= {}
    Legion::Settings[:llm][:routing][:escalation][:enabled] = false
    Legion::Settings[:llm][:streaming][:emit_thinking_blocks] = true
    Legion::Settings[:llm][:streaming][:tool_call_buffering] = :unbuffered
    Legion::Settings[:llm][:api][:debug_formats][:enabled] = true

    # Mark LLM as started without going through the real boot sequence by
    # writing the @started ivar directly. Reset in `restore_started_state!`.
    Legion::LLM.instance_variable_set(:@started, true)
    Legion::LLM::Call::Registry.reset!
    FakeProvider.register!
    FakeProvider.reset!
    Thread.current[:fake_server_tool_round] = 0

    # SSOT v3: activate FakeProvider in the Phase 1 Registry so RoutingSession
    # can find a lane. The offering supports both :chat and :stream_chat.
    Legion::Extensions::Llm::Inventory::Registry.reset!
    SsotV3SnapshotFactory.activate(
      provider_family: 'fake',
      instance_id:     'test',
      drafts:          [
        SsotV3SnapshotFactory.offering_draft(
          model:     FAKE_MODEL,
          tier:      :local,
          supported: %i[chat stream_chat embed count_tokens]
        )
      ],
      callable: FakeProvider.adapter
    )
  end

  # Counterpart to configure_for_fake! — call from `after(:each)` to restore
  # `Legion::LLM.started?` to false so subsequent specs see a clean state.
  def restore_started_state!
    Legion::LLM.instance_variable_set(:@started, nil)
    Legion::Extensions::Llm::Inventory::Registry.reset!
  end

  # Register the LegionIO server-side tool for the execution-proxy spec. The
  # tool injection step picks up `Legion::Settings::Extensions.filter_tools`
  # entries with `deferred: false`; injecting it makes the executor route the
  # tool_call through `:registry` dispatch and execute server-side.
  def register_legion_tool!
    Legion::Settings::Extensions.register_tool(
      FakeLegionEcho.tool_name,
      extension:    'lex-fake',
      runner:       'FakeRunner',
      tool_class:   FakeLegionEcho,
      description:  FakeLegionEcho.description,
      input_schema: FakeLegionEcho.input_schema,
      deferred:     false
    )
  end

  def unregister_legion_tool!
    Legion::Settings::Extensions.unregister_tool(FakeLegionEcho.tool_name)
  rescue StandardError
    nil
  end

  def register_legion_failure_tool!
    Legion::Settings::Extensions.register_tool(
      FakeLegionFailure.tool_name,
      extension:    'lex-fake',
      runner:       'FakeRunner',
      tool_class:   FakeLegionFailure,
      description:  FakeLegionFailure.description,
      input_schema: FakeLegionFailure.input_schema,
      deferred:     false
    )
  end

  def unregister_legion_failure_tool!
    Legion::Settings::Extensions.unregister_tool(FakeLegionFailure.tool_name)
  rescue StandardError
    nil
  end

  # Parse an SSE response body into a list of (event, data-hash) tuples. Lines
  # without `event:` are reported as event=nil. data: [DONE] is reported as
  # event='[DONE]', data=nil.
  def parse_sse(body)
    events = []
    current_event = nil
    body.split("\n").each do |line|
      if line.start_with?('event: ')
        current_event = line.split(': ', 2)[1]
        next
      elsif line.start_with?('data: ')
        data_str = line.split(': ', 2)[1]
        events << if data_str == '[DONE]'
                    ['[DONE]', nil]
                  else
                    [current_event, safe_json_load(data_str)]
                  end
      end
      current_event = nil
    end
    events
  end

  def safe_json_load(str)
    Legion::JSON.load(str)
  rescue StandardError
    nil
  end

  # Return the list of event names from a parsed SSE event list.
  def sse_event_names(parsed_events)
    parsed_events.map { |(name, _data)| name }
  end

  # Return the list of OpenAI Responses API event types from parsed SSE
  # (OpenAI Responses puts the type in the JSON, not the `event:` line for
  # most clients — both are present in our emitter).
  def sse_responses_types(parsed_events)
    parsed_events.filter_map { |(_name, data)| data.is_a?(Hash) ? data[:type] : nil }
  end
end
