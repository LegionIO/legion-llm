# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::TriggerMatch do
  let(:klass) do
    Class.new do
      include Legion::LLM::Inference::Steps::TriggerMatch

      attr_accessor :request, :enrichments, :timeline, :warnings, :triggered_tools

      def initialize(request)
        @request = request
        @enrichments = {}
        @timeline = Legion::LLM::Inference::Timeline.new
        @warnings = []
        @triggered_tools = []
      end
    end
  end

  let(:messages) { [{ role: :user, content: 'show me github pull requests' }] }
  let(:request) do
    Legion::LLM::Inference::Request.build(messages: messages)
  end
  let(:step) { klass.new(request) }

  before do
    Legion::Settings[:llm][:tool_trigger] = { scan_depth: 2, tool_limit: 10 }
    # Remove TriggerIndex constant between examples to avoid bleed-through
    hide_const('Legion::Tools::TriggerIndex') if defined?(Legion::Tools::TriggerIndex)
  end

  describe '#step_trigger_match' do
    context 'when TriggerIndex is not defined' do
      it 'returns without doing anything' do
        expect(step.step_trigger_match).to be_nil
        expect(step.triggered_tools).to be_empty
        expect(step.enrichments).to be_empty
      end
    end

    context 'when TriggerIndex is defined but empty' do
      before do
        stub_const('Legion::Tools::TriggerIndex', Module.new do
          def self.empty? = true
          def self.match(_words) = [Set.new, {}]
        end)
      end

      it 'returns without populating triggered_tools' do
        step.step_trigger_match
        expect(step.triggered_tools).to be_empty
      end
    end

    context 'when TriggerIndex has matches' do
      let(:tool_a) do
        Class.new do
          def self.tool_name = 'github_list_prs'
        end
      end
      let(:tool_b) do
        Class.new do
          def self.tool_name = 'github_create_pr'
        end
      end

      before do
        ta = tool_a
        tb = tool_b
        stub_const('Legion::Tools::TriggerIndex', Module.new do
          define_singleton_method(:empty?) { false }
          define_singleton_method(:match) do |_words|
            matched = Set.new([ta, tb])
            per_word = { 'github' => Set.new([ta, tb]), 'pull' => Set.new([ta]) }
            [matched, per_word]
          end
        end)
      end

      it 'populates triggered_tools' do
        step.step_trigger_match
        expect(step.triggered_tools).not_to be_empty
        expect(step.triggered_tools.map(&:tool_name)).to include('github_list_prs', 'github_create_pr')
      end

      it 'records enrichment entry' do
        step.step_trigger_match
        expect(step.enrichments).to have_key('tool:trigger_match')
        data = step.enrichments['tool:trigger_match']
        expect(data[:data][:tool_count]).to eq(2)
        expect(data[:data][:tool_names]).to include('github_list_prs', 'github_create_pr')
      end

      it 'records a timeline entry' do
        step.step_trigger_match
        keys = step.timeline.events.map { |e| e[:key] }
        expect(keys).to include('tool:trigger_match')
      end
    end

    context 'when matches exceed tool_limit' do
      let(:tools) do
        (1..15).map do |i|
          Class.new do
            define_singleton_method(:tool_name) { "tool_#{i.to_s.rjust(2, '0')}" }
          end
        end
      end

      before do
        ts = tools
        Legion::Settings[:llm][:tool_trigger] = { scan_depth: 2, tool_limit: 5 }
        stub_const('Legion::Tools::TriggerIndex', Module.new do
          define_singleton_method(:empty?) { false }
          define_singleton_method(:match) do |_words|
            matched = Set.new(ts)
            per_word = { 'query' => Set.new(ts.first(10)), 'search' => Set.new(ts.last(8)) }
            [matched, per_word]
          end
        end)
      end

      it 'caps triggered_tools at tool_limit' do
        step.step_trigger_match
        expect(step.triggered_tools.size).to eq(5)
      end
    end

    context 'when always_loaded tools overlap' do
      let(:tool_always) do
        Class.new do
          def self.tool_name = 'always_tool'
        end
      end
      let(:tool_deferred) do
        Class.new do
          def self.tool_name = 'deferred_tool'
        end
      end

      before do
        ta = tool_always
        td = tool_deferred
        stub_const('Legion::Tools::TriggerIndex', Module.new do
          define_singleton_method(:empty?) { false }
          define_singleton_method(:match) do |_words|
            matched = Set.new([ta, td])
            per_word = { 'query' => Set.new([ta, td]) }
            [matched, per_word]
          end
        end)
        stub_const('Legion::Tools::Registry', Module.new do
          define_singleton_method(:always_loaded_names) { ['always_tool'] }
        end)
      end

      it 'excludes always-loaded tools from triggered_tools' do
        step.step_trigger_match
        expect(step.triggered_tools.map(&:tool_name)).not_to include('always_tool')
        expect(step.triggered_tools.map(&:tool_name)).to include('deferred_tool')
      end
    end

    context 'when message content is empty' do
      let(:messages) { [{ role: :user, content: '' }] }

      before do
        stub_const('Legion::Tools::TriggerIndex', Module.new do
          def self.empty? = false
          def self.match(_words) = [Set.new, {}]
        end)
      end

      it 'returns without populating triggered_tools' do
        step.step_trigger_match
        expect(step.triggered_tools).to be_empty
      end
    end
  end

  describe '#normalize_message_words' do
    it 'downcases text' do
      result = step.send(:normalize_message_words, 'Hello World')
      expect(result).to include('hello', 'world')
    end

    it 'strips non-alpha characters' do
      result = step.send(:normalize_message_words, 'hello! world? foo123')
      expect(result).not_to include('hello!')
      expect(result).to include('hello', 'world', 'foo')
    end

    it 'returns a Set (deduplicates)' do
      result = step.send(:normalize_message_words, 'foo foo bar')
      expect(result).to be_a(Set)
      expect(result.count { |w| w == 'foo' }).to eq(1)
    end

    it 'returns empty set for blank text' do
      result = step.send(:normalize_message_words, '   ')
      expect(result).to be_empty
    end
  end

  describe '#extract_recent_text' do
    context 'with Hash messages using symbol keys' do
      let(:messages) { [{ role: :system, content: 'sys' }, { role: :user, content: 'recent query' }] }

      it 'extracts content from last scan_depth messages' do
        text = step.send(:extract_recent_text)
        expect(text).to include('recent query')
      end

      it 'respects scan_depth setting' do
        Legion::Settings[:llm][:tool_trigger] = { scan_depth: 1, tool_limit: 10 }
        step2 = klass.new(Legion::LLM::Inference::Request.build(messages: messages))
        text = step2.send(:extract_recent_text)
        expect(text).to include('recent query')
        expect(text).not_to include('sys')
      end
    end

    context 'with Hash messages using string keys' do
      let(:messages) { [{ 'role' => 'user', 'content' => 'string key content' }] }

      it 'reads content from string-keyed hashes' do
        text = step.send(:extract_recent_text)
        expect(text).to include('string key content')
      end
    end
  end

  describe '#trigger_scan_depth' do
    it 'returns default 2 when settings missing' do
      Legion::Settings[:llm][:tool_trigger] = {}
      expect(step.send(:trigger_scan_depth)).to eq(2)
    end

    it 'reads from settings' do
      Legion::Settings[:llm][:tool_trigger] = { scan_depth: 5, tool_limit: 10 }
      expect(step.send(:trigger_scan_depth)).to eq(5)
    end
  end

  describe '#trigger_tool_limit' do
    it 'returns default 10 when settings missing' do
      Legion::Settings[:llm][:tool_trigger] = {}
      expect(step.send(:trigger_tool_limit)).to eq(50)
    end

    it 'reads from settings' do
      Legion::Settings[:llm][:tool_trigger] = { scan_depth: 2, tool_limit: 7 }
      expect(step.send(:trigger_tool_limit)).to eq(7)
    end
  end
end
