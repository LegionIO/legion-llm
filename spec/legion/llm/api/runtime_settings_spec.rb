# frozen_string_literal: true

require 'spec_helper'
require 'sinatra/base'
require 'tmpdir'
require 'legion/llm/api/native/chat'
require 'legion/llm/api/namespaces/native/chat'
require 'legion/llm/api/namespaces/openai/files'
require 'legion/llm/api/namespaces/openai/batches'
require 'legion/llm/api/namespaces/anthropic/files'

RSpec.describe 'API runtime settings' do
  it 'uses one configured storage root for both file dialects and batch output' do
    Dir.mktmpdir('file-settings') do |root|
      Legion::Settings[:llm][:files][:storage_path] = root
      app = Class.new(Sinatra::Base) do
        register Legion::LLM::API::Namespaces::Anthropic::Files
      end
      expect(app.new!.send(:files_storage_path)).to eq(root)
      expect(Legion::LLM::API::Namespaces::OpenAI::Files.files_dir).to eq(root)
      expect(Legion::LLM::API::Namespaces::OpenAI::Batches.files_dir).to eq(root)
    end
  end

  [Legion::LLM::API::Native::Chat, Legion::LLM::API::Namespaces::Native::Chat].each do |chat|
    it "constructs #{chat.name}'s pool from configuration on first use" do
      chat.shutdown_pool
      Legion::Settings[:llm][:api][:native_chat_pool_size] = 2
      expect(chat.async_pool.max_length).to eq(2)
      expect(chat.async_pool).to equal(chat.async_pool)
      Legion::Settings[:llm][:api][:native_chat_shutdown_timeout] = 0.2
      expect(chat.async_pool).to receive(:wait_for_termination).with(0.2).and_call_original
    ensure
      chat.shutdown_pool
    end
  end

  it 'applies configured diagnostic clipping to actual pipeline log fields' do
    Legion::Settings[:llm][:logging][:pipeline_preview_chars] = 4
    host = Class.new { include Legion::LLM::Inference::Steps::Logging }.new
    expect(host.send(:step_log_safe_value, 'abcdefgh')).to eq('abcd')
    Legion::Settings[:llm][:logging][:pipeline_preview_chars] = 0
    expect(host.send(:step_log_safe_value, 'abcdefgh')).to eq('')
  end
  it 'clips diagnostic and published audit results without truncating stored tool history' do
    Legion::Settings[:llm][:compliance][:tool_audit_result_max_chars] = 4
    request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'test' }])
    executor = Legion::LLM::Inference::Executor.new(request)
    history = executor.instance_variable_get(:@pending_tool_history)
    history << { tool_call_id: 'test-call', result: nil }
    events = []
    executor.instance_variable_set(:@tool_event_handler, ->(event) { events << event })
    result = Struct.new(:tool_call_id, :tool_name, :result, :started_at).new('test-call', 'test-tool', 'abcdefgh', Time.now)
    executor.send(:emit_tool_result_event, result)
    expect(events.last).to include(result: 'abcd', result_size: 8)
    expect(history.last[:result]).to eq('abcdefgh')
    allow(Concurrent::Promises).to receive(:future) { |&job| job.call }
    expect(Legion::LLM::Audit).to receive(:emit_tools).with(hash_including(result: 'abcd'))
    executor.send(:flush_deferred_tool_audits)
  end

  it 'retains deferred audits when their clipping policy is invalid' do
    Legion::Settings[:llm][:compliance][:tool_audit_result_max_chars] = -1
    request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'test' }])
    executor = Legion::LLM::Inference::Executor.new(request)
    executor.send(:publish_tool_audit, 'call', 'tool', 'full result', false, 1, Time.now, Time.now)
    expect { executor.send(:flush_deferred_tool_audits) }.to raise_error(ArgumentError, /tool_audit_result_max_chars/)
    expect(executor.instance_variable_get(:@deferred_tool_audits).first[:result_str]).to eq('full result')
  end
end
