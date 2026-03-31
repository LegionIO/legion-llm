# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/hooks'
require 'legion/llm/hooks/reciprocity'

RSpec.describe Legion::LLM::Hooks::Reciprocity do
  after { Legion::LLM::Hooks.reset! }

  describe '.install' do
    it 'registers an after_chat hook' do
      expect { described_class.install }.to change {
        Legion::LLM::Hooks.instance_variable_get(:@after_chat).size
      }.by(1)
    end
  end

  describe '.record_reciprocity' do
    context 'when caller has identity' do
      let(:caller) { { requested_by: { identity: 'agent:alpha', type: :agent } } }

      it 'calls record_exchange on the social runner' do
        runner = double('social_runner')
        allow(described_class).to receive(:social_runner).and_return(runner)
        expect(runner).to receive(:record_exchange).with(
          agent_id:  'agent:alpha',
          action:    :communication,
          direction: :given
        )
        described_class.record_reciprocity(caller: caller)
      end
    end

    context 'when caller has no identity' do
      let(:caller) { { requested_by: { type: :system } } }

      it 'skips without error' do
        expect(described_class).not_to receive(:social_runner)
        expect { described_class.record_reciprocity(caller: caller) }.not_to raise_error
      end
    end

    context 'when caller is nil' do
      it 'skips without error' do
        expect(described_class).not_to receive(:social_runner)
        expect { described_class.record_reciprocity(caller: nil) }.not_to raise_error
      end
    end

    context 'when social runner is unavailable' do
      let(:caller) { { requested_by: { identity: 'agent:alpha', type: :agent } } }

      it 'skips without error' do
        allow(described_class).to receive(:social_runner).and_return(nil)
        expect { described_class.record_reciprocity(caller: caller) }.not_to raise_error
      end
    end

    context 'when social runner raises an error' do
      let(:caller) { { requested_by: { identity: 'agent:alpha', type: :agent } } }

      it 'rescues and does not propagate' do
        runner = double('social_runner')
        allow(described_class).to receive(:social_runner).and_return(runner)
        allow(runner).to receive(:record_exchange).and_raise(StandardError, 'boom')
        expect { described_class.record_reciprocity(caller: caller) }.not_to raise_error
      end
    end
  end

  describe '.social_runner' do
    it 'returns nil when Social extension is not defined' do
      hide_const('Legion::Extensions::Agentic::Social') if defined?(Legion::Extensions::Agentic::Social)
      expect(described_class.social_runner).to be_nil
    end

    it 'returns a client when Social extension is defined' do
      social_mod = Module.new
      social_social_mod = Module.new
      client_class = Class.new do
        def record_exchange(**); end
      end
      social_social_mod.const_set(:Client, client_class)
      social_mod.const_set(:Social, social_social_mod)
      stub_const('Legion::Extensions::Agentic::Social', social_mod)
      stub_const('Legion::Extensions::Agentic::Social::Social', social_social_mod)
      stub_const('Legion::Extensions::Agentic::Social::Social::Client', client_class)

      result = described_class.social_runner
      expect(result).to be_a(client_class)
    end
  end

  describe 'after_chat hook integration' do
    it 'calls record_reciprocity with the caller kwarg' do
      described_class.install
      caller_hash = { requested_by: { identity: 'agent:beta', type: :agent } }
      allow(described_class).to receive(:record_reciprocity)

      Legion::LLM::Hooks.run_after(
        response: { content: 'hello' },
        messages: [{ role: :user, content: 'hi' }],
        model:    'claude-sonnet-4-6',
        caller:   caller_hash
      )

      expect(described_class).to have_received(:record_reciprocity).with(caller: caller_hash)
    end

    it 'handles missing caller kwarg gracefully' do
      described_class.install
      expect do
        Legion::LLM::Hooks.run_after(
          response: { content: 'hello' },
          messages: [],
          model:    'test-model'
        )
      end.not_to raise_error
    end
  end
end
