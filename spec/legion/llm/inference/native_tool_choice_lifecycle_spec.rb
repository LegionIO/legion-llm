# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Native tool choice lifecycle' do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages:    [{ role: :user, content: 'run bash' }],
      routing:     { provider: :native_choice_spec, model: 'native-choice-model' },
      tools:       [Legion::LLM::Types::ToolDefinition.build(name: 'bash')],
      tool_choice: { type: :tool, name: 'bash' }
    )
  end
  let(:executor) do
    Legion::LLM::Inference::Executor.new(request).tap do |instance|
      instance.instance_variable_set(:@resolved_provider, :native_choice_spec)
      instance.instance_variable_set(:@native_dispatch_tools, {
                                       bash: Legion::Extensions::Llm::Canonical::ToolDefinition.build(
                                         name: 'bash', description: '', parameters: {}, source: {}
                                       )
                                     })
    end
  end

  around do |example|
    keys = %i[legion_current_tool_history_index legion_current_tool_call_id legion_current_tool_name legion_current_tool_started_at]
    prior = keys.to_h { |key| [key, Thread.current[key]] }
    example.run
  ensure
    prior.each { |key, value| Thread.current[key] = value }
  end

  def record_server_call(executor, name:, status: :success, result: 'done', source: :registry)
    executor.send(
      :emit_tool_call_event,
      { id: "call_#{name}", name: name, arguments: {} },
      1,
      source: { type: source }
    )
    executor.send(
      :emit_tool_result_event,
      Legion::LLM::Inference::Executor::ToolResultEvent.new(
        result:       result,
        tool_call_id: "call_#{name}",
        tool_name:    name,
        status:       status
      )
    )
  end

  describe 'an explicit named choice' do
    it 'forces the named tool on the initial dispatch' do
      expect(executor.send(:native_tool_prefs)).to include(choice: 'bash')
    end

    it 'uses automatic choice after the named server call completes' do
      record_server_call(executor, name: 'bash')
      executor.instance_variable_set(:@native_tool_loop_round, 1)

      expect(executor.send(:native_tool_prefs)).to include(choice: :auto)
    end

    it 'keeps the named choice when only another tool completed' do
      record_server_call(executor, name: 'other_tool')
      executor.instance_variable_set(:@native_tool_loop_round, 2)

      expect(executor.send(:native_tool_prefs)).to include(choice: 'bash')
    end

    it 'keeps the named choice when the named call is only pending' do
      executor.send(
        :emit_tool_call_event,
        { id: 'call_bash', name: 'bash', arguments: {} },
        1,
        source: { type: :registry }
      )
      executor.instance_variable_set(:@native_tool_loop_round, 2)

      expect(executor.send(:native_tool_prefs)).to include(choice: 'bash')
    end

    it 'does not release the named choice merely because another round started' do
      executor.instance_variable_set(:@native_tool_loop_round, 3)

      expect(executor.send(:native_tool_prefs)).to include(choice: 'bash')
    end

    it 'does not mutate the original request choice' do
      original_choice = request.tool_choice

      record_server_call(executor, name: 'bash')
      executor.instance_variable_set(:@native_tool_loop_round, 1)
      executor.send(:native_tool_prefs)

      expect(request.tool_choice).to equal(original_choice)
      expect(request.tool_choice).to eq(type: :tool, name: 'bash')
    end

    it 'does not treat a completed client call as server execution' do
      record_server_call(executor, name: 'bash', source: :client)
      executor.instance_variable_set(:@native_tool_loop_round, 1)

      expect(executor.send(:native_tool_prefs)).to include(choice: 'bash')
    end
  end

  describe 'existing choice modes' do
    it 'preserves automatic choice and calls' do
      auto_request = request.with(tool_choice: { mode: :auto, calls: %w[bash other_tool] })
      auto_executor = Legion::LLM::Inference::Executor.new(auto_request)

      expect(auto_executor.send(:native_tool_prefs)).to eq(choice: :auto, calls: %w[bash other_tool])
    end

    it 'preserves none' do
      none_executor = Legion::LLM::Inference::Executor.new(request.with(tool_choice: { mode: :none }))

      expect(none_executor.send(:native_tool_prefs)).to eq(choice: :none)
    end

    it 'preserves required' do
      required_executor = Legion::LLM::Inference::Executor.new(request.with(tool_choice: { mode: :required }))

      expect(required_executor.send(:native_tool_prefs)).to eq(choice: :required)
    end
  end

  describe 'canonical execution results' do
    it 'preserves the full result and ownership for the stream observer and final response' do
      result = Legion::JSON.dump({ tools: Array.new(400) { |index| "tool_#{index}" }, tail: 'inventory_end' })
      observer = double('stream observer', server_tool_started: nil)
      executor.instance_variable_set(:@stream_observer, observer)
      expect(observer).to receive(:server_tool_completed) do |tool_call:|
        expect(tool_call).to be_a(Legion::Extensions::Llm::Canonical::ToolCall)
        expect(tool_call.id).to eq('call_inventory')
        expect(tool_call.source).to eq(:special)
        expect(tool_call.status).to eq(:success)
        expect(tool_call.result).to eq(result)
      end

      record_server_call(executor, name: 'inventory', source: :special, result: result)

      recorded = executor.instance_variable_get(:@pending_tool_history).last.fetch(:typed_call)
      expect(recorded.result).to eq(result)
      expect(Legion::JSON.load(recorded.result)).to include(tail: 'inventory_end')
    end
  end

  describe 'the round-zero text mention heuristic' do
    before do
      @previous_explicit_tool_choice = Legion::Settings[:llm][:tools][:explicit_tool_choice]
      translator = Struct.new(:capabilities).new({ forced_tool_choice: true })
      provider = Module.new do
        define_singleton_method(:translator) { translator }
      end
      Legion::LLM::Call::Registry.register(:native_choice_spec, provider)
      Legion::Settings[:llm][:tools][:explicit_tool_choice] = true
    end

    after do
      Legion::LLM::Call::Registry.deregister_provider(:native_choice_spec)
      Legion::Settings[:llm][:tools][:explicit_tool_choice] = @previous_explicit_tool_choice
    end

    it 'still forces a mentioned tool only on round zero' do
      auto_request = request.with(tool_choice: { mode: :auto })
      auto_executor = Legion::LLM::Inference::Executor.new(auto_request)
      auto_executor.instance_variable_set(:@resolved_provider, :native_choice_spec)
      auto_executor.instance_variable_set(:@native_dispatch_tools, executor.instance_variable_get(:@native_dispatch_tools))

      expect(auto_executor.send(:native_tool_prefs)).to include(choice: 'bash')

      auto_executor.instance_variable_set(:@native_tool_loop_round, 1)
      expect(auto_executor.send(:native_tool_prefs)).to include(choice: :auto)
    end
  end
end
