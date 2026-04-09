# frozen_string_literal: true

require 'spec_helper'
require_relative '../../support/transport_stub'
require 'legion/llm/audit'

RSpec.describe Legion::LLM::Audit do
  let(:prompt_event) { { request_type: 'chat', provider: 'ollama' } }
  let(:tool_event) { { tool_name: 'list_files', provider: 'ollama' } }

  describe '.emit_prompt' do
    it 'returns :dropped when transport not connected' do
      expect(described_class.emit_prompt(prompt_event)).to eq(:dropped)
    end

    it 'returns :published when transport connected' do
      stub_const('Legion::Transport', Module.new)
      allow(Legion::Transport).to receive(:connected?).and_return(true)
      msg_instance = instance_double(Legion::LLM::Audit::PromptEvent)
      allow(Legion::LLM::Audit::PromptEvent).to receive(:new).and_return(msg_instance)
      allow(msg_instance).to receive(:publish)

      expect(described_class.emit_prompt(prompt_event)).to eq(:published)
    end

    it 'never raises' do
      stub_const('Legion::Transport', Module.new)
      allow(Legion::Transport).to receive(:connected?).and_return(true)
      allow(Legion::LLM::Audit::PromptEvent).to receive(:new).and_raise(StandardError, 'boom')

      expect { described_class.emit_prompt(prompt_event) }.not_to raise_error
      expect(described_class.emit_prompt(prompt_event)).to eq(:dropped)
    end
  end

  describe '.emit_tools' do
    it 'returns :dropped when transport not connected' do
      expect(described_class.emit_tools(tool_event)).to eq(:dropped)
    end

    it 'returns :published when transport connected' do
      stub_const('Legion::Transport', Module.new)
      allow(Legion::Transport).to receive(:connected?).and_return(true)
      msg_instance = instance_double(Legion::LLM::Audit::ToolEvent)
      allow(Legion::LLM::Audit::ToolEvent).to receive(:new).and_return(msg_instance)
      allow(msg_instance).to receive(:publish)

      expect(described_class.emit_tools(tool_event)).to eq(:published)
    end

    it 'never raises' do
      stub_const('Legion::Transport', Module.new)
      allow(Legion::Transport).to receive(:connected?).and_return(true)
      allow(Legion::LLM::Audit::ToolEvent).to receive(:new).and_raise(StandardError, 'boom')

      expect { described_class.emit_tools(tool_event) }.not_to raise_error
      expect(described_class.emit_tools(tool_event)).to eq(:dropped)
    end
  end
end
