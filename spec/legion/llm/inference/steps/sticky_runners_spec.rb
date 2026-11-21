# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../support/tool_registry'

RSpec.describe Legion::LLM::Inference::Steps::StickyRunners, tool_registry: true do
  let(:klass) do
    Class.new do
      include Legion::LLM::Inference::Steps::StickyRunners

      attr_accessor :request, :triggered_tools, :enrichments, :sticky_turn_snapshot,
                    :freshly_triggered_keys, :warnings

      def initialize
        @triggered_tools        = []
        @enrichments            = {}
        @sticky_turn_snapshot   = nil
        @freshly_triggered_keys = []
        @warnings               = []
      end

      def timeline = @timeline ||= double(record: nil)
      def sticky_enabled? = true
      def handle_exception(err, **) = @warnings << err.message
    end
  end

  let(:instance) { klass.new }

  def fake_request(conv_id)
    double(conversation_id: conv_id)
  end

  describe '#step_sticky_runners' do
    before do
      allow(Legion::LLM::Inference::Conversation).to receive(:messages).and_return([
                                                                                     { role: :user, content: 'hello' },
                                                                                     { role: :assistant, content: 'hi' },
                                                                                     { role: :user,      content: 'for issues in github' }
                                                                                   ])
      allow(Legion::LLM::Inference::Conversation).to receive(:read_sticky_state).and_return({})
    end

    it 'sets @sticky_turn_snapshot to count of user-role messages only' do
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_runners
      expect(instance.sticky_turn_snapshot).to eq(2)
    end

    it 'captures @freshly_triggered_keys BEFORE re-injection loop' do
      tool_a = double(tool_name: 'tool-a', extension: 'github', runner: 'issues', sticky: true)
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.triggered_tools << tool_a
      instance.step_sticky_runners
      expect(instance.freshly_triggered_keys).to eq(['github_issues'])
    end

    it 'does NOT include re-injected sticky runners in @freshly_triggered_keys' do
      tool_a = double(tool_name: 'tool-a', extension: 'github', runner: 'issues', sticky: true)
      tool_b_entry = { name: 'tool-b', extension: 'github', runner: 'branches', sticky: true, deferred: true }
      instance.triggered_tools << tool_a
      register_tool_entries([tool_b_entry])
      allow(Legion::LLM::Inference::Conversation).to receive(:read_sticky_state).and_return(
        sticky_runners:      { 'github_branches' => { tier: :executed, expires_after_deferred_call: 10 } },
        deferred_tool_calls: 3
      )
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_runners
      expect(instance.freshly_triggered_keys).to eq(['github_issues'])
      expect(instance.freshly_triggered_keys).not_to include('github_branches')
      expect(instance.triggered_tools).to include(Legion::Settings::Extensions.find_tool(tool_b_entry[:name]))
    end

    it 're-injects live execution-sticky runner tools into @triggered_tools' do
      tool_b_entry = { name: 'tool-b', extension: 'github', runner: 'issues', sticky: true, deferred: true }
      register_tool_entries([tool_b_entry])
      allow(Legion::LLM::Inference::Conversation).to receive(:read_sticky_state).and_return(
        sticky_runners:      { 'github_issues' => { tier: :executed, expires_after_deferred_call: 10 } },
        deferred_tool_calls: 3
      )
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_runners
      expect(instance.triggered_tools).to include(Legion::Settings::Extensions.find_tool(tool_b_entry[:name]))
    end

    it 'does NOT re-inject expired runners' do
      tool_c_entry = { name: 'tool-c', extension: 'github', runner: 'issues', sticky: true, deferred: true }
      register_tool_entries([tool_c_entry])
      allow(Legion::LLM::Inference::Conversation).to receive(:read_sticky_state).and_return(
        sticky_runners:      { 'github_issues' => { tier: :executed, expires_after_deferred_call: 3 } },
        deferred_tool_calls: 5
      )
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_runners
      expect(instance.triggered_tools).not_to include(Legion::Settings::Extensions.find_tool(tool_c_entry[:name]))
    end

    it 'does NOT re-inject tools with sticky: false' do
      tool_d_entry = { name: 'tool-d', extension: 'github', runner: 'issues', sticky: false, deferred: true }
      register_tool_entries([tool_d_entry])
      allow(Legion::LLM::Inference::Conversation).to receive(:read_sticky_state).and_return(
        sticky_runners:      { 'github_issues' => { tier: :executed, expires_after_deferred_call: 10 } },
        deferred_tool_calls: 3
      )
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_runners
      expect(instance.triggered_tools).not_to include(Legion::Settings::Extensions.find_tool(tool_d_entry[:name]))
    end

    it 'returns early and does NOT set snapshot when conv_id is nil' do
      instance.instance_variable_set(:@request, fake_request(nil))
      instance.step_sticky_runners
      expect(instance.sticky_turn_snapshot).to be_nil
    end
  end
end
