# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::ToolHistory do
  let(:klass) do
    Class.new do
      include Legion::LLM::Inference::Steps::ToolHistory

      attr_accessor :request, :enrichments, :warnings

      def initialize
        @enrichments = {}
        @warnings    = []
      end

      def sticky_enabled? = true
      def handle_exception(err, **) = @warnings << err.message
    end
  end

  let(:instance) { klass.new }

  def fake_request(conv_id)
    double(conversation_id: conv_id)
  end

  describe '#step_tool_history_inject' do
    it 'does nothing when history is empty' do
      allow(Legion::LLM::Inference::Conversation).to receive(:read_sticky_state).and_return({})
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_tool_history_inject
      expect(instance.enrichments['tool:call_history']).to be_nil
    end

    it 'sets enrichment with content/data/timestamp structure' do
      history = [{ tool: 'legion-github-issues-list_issues', runner: 'github_issues',
                   turn: 3, args: { owner: 'LegionIO' }, result: '{"result":[]}', error: false }]
      allow(Legion::LLM::Inference::Conversation).to receive(:read_sticky_state)
        .and_return({ tool_call_history: history })
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_tool_history_inject
      enrichment = instance.enrichments['tool:call_history']
      expect(enrichment[:content]).to include('Tools used in this conversation:')
      expect(enrichment[:data][:entry_count]).to eq(1)
      expect(enrichment[:timestamp]).to be_a(Time)
    end

    it 'returns early when conv_id is nil' do
      instance.instance_variable_set(:@request, fake_request(nil))
      instance.step_tool_history_inject
      expect(instance.enrichments['tool:call_history']).to be_nil
    end
  end

  describe '#summarize_result' do
    subject { instance }

    it 'returns error prefix when error is true' do
      expect(subject.send(:summarize_result, 'oops', true)).to start_with('error: oops')
    end

    it 'returns N items returned for array results' do
      json = Legion::JSON.dump([1, 2, 3])
      expect(subject.send(:summarize_result, json, false)).to eq('3 items returned')
    end

    it 'returns #N at URL for github-style results with number and html_url' do
      json = Legion::JSON.dump({ number: 42, html_url: 'https://github.com/foo/bar/issues/42' })
      expect(subject.send(:summarize_result, json, false)).to eq('#42 at https://github.com/foo/bar/issues/42')
    end

    it 'returns N items returned for nested result array' do
      json = Legion::JSON.dump({ result: [{ id: 1 }, { id: 2 }] })
      expect(subject.send(:summarize_result, json, false)).to eq('2 items returned')
    end

    it 'falls back to first 200 chars for unrecognized structures' do
      long_str = 'x' * 300
      expect(subject.send(:summarize_result, long_str, false).length).to eq(200)
    end

    it 'falls back gracefully on unparseable JSON' do
      expect(subject.send(:summarize_result, '{bad json', false)).to eq('{bad json'[0, 200])
    end

    it 'falls back to first 200 chars when parsed[:result] is a plain String' do
      json = Legion::JSON.dump({ result: 'Created successfully' })
      expect(subject.send(:summarize_result, json, false)).to eq(json[0, 200])
    end
  end

  describe '#format_history_entry' do
    it 'formats args as key: value pairs with JSON for non-strings' do
      entry = { tool: 'my_tool', turn: 2,
                args: { owner: 'LegionIO', filters: { state: 'open' } },
                result: '[]', error: false }
      line = instance.send(:format_history_entry, entry)
      expect(line).to include('owner: LegionIO')
      expect(line).to include('"state"')
      expect(line).to include('"open"')
      expect(line).to start_with('- Turn 2:')
    end
  end
end
