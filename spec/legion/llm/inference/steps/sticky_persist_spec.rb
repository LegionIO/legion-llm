# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::StickyPersist do
  let(:klass) do
    Class.new do
      include Legion::LLM::Inference::Steps::StickyPersist

      attr_accessor :request, :pending_tool_history, :injected_tool_map,
                    :freshly_triggered_keys, :sticky_turn_snapshot, :warnings

      def initialize
        @pending_tool_history    = Concurrent::Array.new
        @injected_tool_map       = {}
        @freshly_triggered_keys  = []
        @sticky_turn_snapshot    = 3
        @warnings                = []
      end

      def sticky_enabled?             = true
      def handle_exception(err, **) = @warnings << err.message
      def max_history_entries         = 50
      def max_result_length           = 2000
      def max_args_length             = 500
      def trigger_sticky_turns        = 2
      def execution_sticky_tool_calls = 5
    end
  end

  let(:instance) { klass.new }

  def fake_request(conv_id)
    double(conversation_id: conv_id)
  end

  def deferred_tool(name, ext, runner)
    double(tool_name: name, extension: ext, runner: runner, deferred?: true)
  end

  before do
    unless defined?(Legion::Tools::Registry)
      stub_const('Legion::Tools::Registry', Module.new do
        def self.all_tools = []
      end)
    end

    allow(Legion::LLM::Inference::Conversation).to receive(:read_sticky_state).and_return({})
    allow(Legion::LLM::Inference::Conversation).to receive(:write_sticky_state)
    allow(Legion::Tools::Registry).to receive(:all_tools).and_return([])
  end

  describe '#step_sticky_persist' do
    it 'returns early when sticky_turn_snapshot is nil (profile-skipped)' do
      instance.sticky_turn_snapshot = nil
      instance.instance_variable_set(:@request, fake_request('c1'))
      expect(Legion::LLM::Inference::Conversation).not_to receive(:write_sticky_state)
      instance.step_sticky_persist
    end

    it 'returns early when conv_id is nil' do
      instance.instance_variable_set(:@request, fake_request(nil))
      expect(Legion::LLM::Inference::Conversation).not_to receive(:write_sticky_state)
      instance.step_sticky_persist
    end

    it 'increments deferred_tool_calls by number of completed deferred tools' do
      tc = deferred_tool('legion-github-issues-list_issues', 'github', 'issues')
      instance.injected_tool_map['legion-github-issues-list_issues'] = tc
      instance.pending_tool_history << {
        tool_name: 'legion-github-issues-list_issues', result: '{}', error: false, runner_key: nil
      }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::Inference::Conversation).to have_received(:write_sticky_state) do |_, state|
        expect(state[:deferred_tool_calls]).to eq(1)
      end
    end

    it 'does NOT count errored tool calls toward deferred counter' do
      tc = deferred_tool('tool-err', 'github', 'issues')
      instance.injected_tool_map['tool-err'] = tc
      instance.pending_tool_history << {
        tool_name: 'tool-err', result: '{"error":"fail"}', error: true, runner_key: nil
      }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::Inference::Conversation).to have_received(:write_sticky_state) do |_, state|
        expect(state[:deferred_tool_calls]).to eq(0)
      end
    end

    it 'sets execution-tier stickiness for executed runner' do
      tc = deferred_tool('tool-a', 'github', 'issues')
      instance.injected_tool_map['tool-a'] = tc
      instance.pending_tool_history << { tool_name: 'tool-a', result: '{}', error: false, runner_key: nil }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::Inference::Conversation).to have_received(:write_sticky_state) do |_, state|
        runner_entry = state[:sticky_runners]['github_issues']
        expect(runner_entry[:tier]).to eq(:executed)
        expect(runner_entry[:expires_after_deferred_call]).to eq(1 + 5)
      end
    end

    it 'sets trigger-tier stickiness only for freshly triggered keys (not re-injected)' do
      instance.freshly_triggered_keys = ['github_branches']
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::Inference::Conversation).to have_received(:write_sticky_state) do |_, state|
        branch_entry = state[:sticky_runners]['github_branches']
        expect(branch_entry[:tier]).to eq(:triggered)
        expect(branch_entry[:expires_at_turn]).to eq(6) # snapshot=3, trigger_turns=2, +1
      end
    end

    it 'does NOT refresh trigger window for runners not in freshly_triggered_keys' do
      instance.freshly_triggered_keys = []
      instance.instance_variable_set(:@request, fake_request('c1'))
      allow(Legion::LLM::Inference::Conversation).to receive(:read_sticky_state)
        .and_return({ sticky_runners: { 'github_issues' => { tier: :triggered, expires_at_turn: 10 } } })
      instance.step_sticky_persist

      expect(Legion::LLM::Inference::Conversation).to have_received(:write_sticky_state) do |_, state|
        expect(state[:sticky_runners]['github_issues'][:expires_at_turn]).to eq(10)
      end
    end

    it 'appends tool call records to tool_call_history' do
      instance.pending_tool_history << {
        tool_name: 'my-tool', result: '{"result":[1,2]}', error: false,
        runner_key: 'my_runner', args: { q: 'test' }
      }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::Inference::Conversation).to have_received(:write_sticky_state) do |_, state|
        entry = state[:tool_call_history].first
        expect(entry[:tool]).to eq('my-tool')
        expect(entry[:runner]).to eq('my_runner')
        expect(entry[:turn]).to eq(3)
      end
    end

    it 'trims tool_call_history to max_history_entries' do
      allow(instance).to receive(:max_history_entries).and_return(2)
      existing = Array.new(3) { |i| { tool: "t#{i}", runner: 'r', turn: i, args: {}, result: '{}', error: false } }
      allow(Legion::LLM::Inference::Conversation).to receive(:read_sticky_state)
        .and_return({ tool_call_history: existing })
      instance.pending_tool_history << { tool_name: 'new', result: '{}', error: false, runner_key: 'r', args: {} }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::Inference::Conversation).to have_received(:write_sticky_state) do |_, state|
        expect(state[:tool_call_history].size).to eq(2)
      end
    end

    it 'redacts sensitive arg keys' do
      instance.pending_tool_history << {
        tool_name: 'my-tool', result: '{}', error: false,
        runner_key: 'r', args: { api_key: 'secret123', owner: 'LegionIO' }
      }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::Inference::Conversation).to have_received(:write_sticky_state) do |_, state|
        entry = state[:tool_call_history].first
        expect(entry[:args][:api_key]).to eq('[REDACTED]')
        expect(entry[:args][:owner]).to eq('LegionIO')
      end
    end

    it 'resolves tool class via Registry snapshot when @injected_tool_map misses (native dispatch path)' do
      tc = deferred_tool('legion-github-issues-list_issues', 'github', 'issues')
      allow(Legion::Tools::Registry).to receive(:all_tools).and_return([tc])
      instance.pending_tool_history << {
        tool_name: 'legion-github-issues-list_issues', result: '{}', error: false, runner_key: nil
      }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::Inference::Conversation).to have_received(:write_sticky_state) do |_, state|
        expect(state[:sticky_runners]['github_issues']).not_to be_nil
        expect(state[:sticky_runners]['github_issues'][:tier]).to eq(:executed)
        expect(state[:tool_call_history].first[:runner]).to eq('github_issues')
      end
    end

    it 're-activates expired execution-sticky runner under trigger tier when freshly triggered' do
      allow(Legion::LLM::Inference::Conversation).to receive(:read_sticky_state).and_return({
                                                                                              sticky_runners:      {
                                                                                                'github_issues' => { tier:                        :executed,
                                                                                                                     expires_after_deferred_call: 0 }
                                                                                              },
                                                                                              deferred_tool_calls: 0
                                                                                            })
      instance.freshly_triggered_keys = ['github_issues']
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::Inference::Conversation).to have_received(:write_sticky_state) do |_, state|
        entry = state[:sticky_runners]['github_issues']
        expect(entry[:tier]).to eq(:triggered)
        expect(entry[:expires_at_turn]).to eq(3 + 2 + 1)
      end
    end
  end
end
