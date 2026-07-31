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
    Legion::Settings[:llm][:tool_trigger] = { scan_depth: 10, tool_limit: 50 }
    hide_const('Legion::Settings::Extensions') if defined?(Legion::Settings::Extensions)
  end

  describe '#step_trigger_match' do
    context 'when Settings::Extensions is not defined' do
      it 'returns without doing anything' do
        step.step_trigger_match
        expect(step.triggered_tools).to be_empty
        expect(step.enrichments).to be_empty
        expect(step.warnings).to be_empty
      end
    end

    context 'when Settings::Extensions has no tools' do
      before do
        stub_const('Legion::Settings::Extensions', Module.new do
          def self.tools = []
          def self.filter_tools(**) = []
        end)
      end

      it 'returns without populating triggered_tools' do
        step.step_trigger_match
        expect(step.triggered_tools).to be_empty
      end
    end

    context 'when Settings::Extensions has matches' do
      let(:tool_a) { { name: 'github_list_prs', extension: 'lex-github', runner: 'pull_requests', function: 'list' } }
      let(:tool_b) { { name: 'github_create_pr', extension: 'lex-github', runner: 'pull_requests', function: 'create' } }

      before do
        ta = tool_a
        tb = tool_b
        stub_const('Legion::Settings::Extensions', Module.new do
          define_singleton_method(:tools) { [ta, tb] }
          define_singleton_method(:filter_tools) { |**| [] }
        end)
      end

      it 'populates triggered_tools' do
        step.step_trigger_match
        expect(step.triggered_tools).not_to be_empty
        expect(step.triggered_tools.map { |tool| tool[:name] }).to include('github_list_prs', 'github_create_pr')
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
          { name: "tool_#{i.to_s.rjust(2, '0')}", trigger_words: %w[github pull requests] }
        end
      end

      before do
        ts = tools
        Legion::Settings[:llm][:tool_trigger] = { scan_depth: 2, tool_limit: 5 }
        stub_const('Legion::Settings::Extensions', Module.new do
          define_singleton_method(:tools) { ts }
          define_singleton_method(:filter_tools) { |**| [] }
        end)
      end

      it 'caps triggered_tools at tool_limit' do
        step.step_trigger_match
        expect(step.triggered_tools.size).to eq(5)
      end
    end

    context 'when always_loaded tools overlap' do
      let(:tool_always) { { name: 'always_tool', trigger_words: %w[github] } }
      let(:tool_deferred) { { name: 'deferred_tool', trigger_words: %w[github] } }

      before do
        ta = tool_always
        td = tool_deferred
        extensions_mod = Module.new do
          define_singleton_method(:tools) do
            [ta, td]
          end
          define_singleton_method(:filter_tools) do |**criteria|
            if criteria[:deferred] == false
              [{ name: 'always_tool' }]
            else
              []
            end
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)
      end

      it 'excludes always-loaded tools from triggered_tools' do
        step.step_trigger_match
        expect(step.triggered_tools.map { |tool| tool[:name] }).not_to include('always_tool')
        expect(step.triggered_tools.map { |tool| tool[:name] }).to include('deferred_tool')
      end
    end

    context 'when message content is empty' do
      let(:messages) { [{ role: :user, content: '' }] }

      before do
        stub_const('Legion::Settings::Extensions', Module.new do
          def self.tools = [{ name: 'github_list_prs', trigger_words: %w[github] }]
          def self.filter_tools(**) = []
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

    context 'with system-reminder markup embedded in user content' do
      let(:messages) do
        [
          {
            role:    :user,
            content: '<system-reminder>startup handoff tool routing instructions</system-reminder>hello who are you'
          }
        ]
      end

      it 'strips system-reminder blocks only from trigger matching text' do
        text = step.send(:extract_recent_text)

        expect(text).to eq(' hello who are you')
        expect(request.messages.first[:content]).to include('<system-reminder>')
      end
    end

    context 'with session markup embedded in user content' do
      let(:messages) do
        [
          {
            role:    :user,
            content: "<session>\nhello who are you\n</session>\n\nWrite the title in the language the user wrote in"
          }
        ]
      end

      it 'uses only session content for trigger matching text' do
        text = step.send(:extract_recent_text)

        expect(text).to eq("\nhello who are you\n")
        expect(text).not_to include('Write the title')
        expect(request.messages.first[:content]).to include('Write the title')
      end
    end

    context 'with system-reminder and session markup in the same user content' do
      let(:messages) do
        [
          {
            role:    :user,
            content: '<system-reminder>startup handoff tool routing instructions</system-reminder>' \
                     "<session>\nhello who are you\n</session>\n\nWrite the title in the language"
          }
        ]
      end

      it 'removes system reminders and uses only session content' do
        text = step.send(:extract_recent_text)

        expect(text).to eq("\nhello who are you\n")
        expect(text).not_to include('startup handoff')
        expect(text).not_to include('Write the title')
      end
    end
  end

  describe '#trigger_scan_depth' do
    it 'returns registered default 10 from settings' do
      Legion::Settings[:llm][:tool_trigger][:scan_depth] = 10
      expect(step.send(:trigger_scan_depth)).to eq(10)
    end

    it 'reads from settings' do
      Legion::Settings[:llm][:tool_trigger] = { scan_depth: 5, tool_limit: 10 }
      expect(step.send(:trigger_scan_depth)).to eq(5)
    end

    it 'reads from settings via set_prop' do
      Legion::Settings.set_prop(:llm, {
                                  tool_trigger: {
                                    scan_depth: 3,
                                    tool_limit: 8
                                  }
                                })
      expect(step.send(:trigger_scan_depth)).to eq(3)
    end
  end

  describe '#trigger_tool_limit' do
    it 'returns registered default 25 from settings' do
      Legion::Settings[:llm][:tool_trigger][:tool_limit] = 25
      expect(step.send(:trigger_tool_limit)).to eq(25)
    end

    it 'reads from settings' do
      Legion::Settings[:llm][:tool_trigger] = { scan_depth: 2, tool_limit: 7 }
      expect(step.send(:trigger_tool_limit)).to eq(7)
    end

    it 'reads from settings via set_prop' do
      Legion::Settings.set_prop(:llm, {
                                  tool_trigger: {
                                    scan_depth: 3,
                                    tool_limit: 8
                                  }
                                })
      expect(step.send(:trigger_tool_limit)).to eq(8)
    end
  end
end
