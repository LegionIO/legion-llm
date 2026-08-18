# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/openai/responses'

RSpec.describe Legion::LLM::API::OpenAI::Responses do
  describe '.normalize_input_array' do
    it 'normalizes standard message objects' do
      input = [
        { role: 'user', content: 'hello' },
        { role: 'assistant', content: 'hi' }
      ]
      result = described_class.normalize_input_array(input)
      expect(result).to eq([
                             { role: 'user', content: 'hello' },
                             { role: 'assistant', content: 'hi' }
                           ])
    end

    it 'normalizes function_call_output items to tool role' do
      input = [
        { type: 'function_call_output', call_id: 'call_123', output: '{"result": 42}' }
      ]
      result = described_class.normalize_input_array(input)
      expect(result).to eq([
                             { role: 'tool', tool_call_id: 'call_123', content: '{"result": 42}' }
                           ])
    end

    it 'skips items without a role or recognized type' do
      input = [{ content: 'orphan' }]
      result = described_class.normalize_input_array(input)
      expect(result).to eq([])
    end

    it 'maps developer role to system' do
      result = described_class.normalize_input_array([{ role: 'developer', content: 'Be an expert.' }])
      expect(result).to eq([{ role: 'system', content: 'Be an expert.' }])
    end
  end

  describe '.build_tool_declarations' do
    it 'returns empty array for nil' do
      expect(described_class.build_tool_declarations(nil)).to eq([])
    end

    it 'builds tool definitions from function-wrapped tools' do
      tools = [
        { type: 'function', function: { name: 'get_weather', description: 'Gets weather', parameters: { type: 'object' } } }
      ]
      result = described_class.build_tool_declarations(tools)
      expect(result.size).to eq(1)
      expect(result.first.name).to eq('get_weather')
    end

    it 'builds tool definitions from flat tools' do
      tools = [
        { name: 'search', description: 'Search things', parameters: {} }
      ]
      result = described_class.build_tool_declarations(tools)
      expect(result.size).to eq(1)
      expect(result.first.name).to eq('search')
    end
  end

  describe '.format_response' do
    let(:pipeline_response) do
      double(
        'PipelineResponse',
        routing: { model: 'gpt-4o', provider: 'openai' },
        tokens:  { input: 15, output: 25 },
        message: { content: 'Hello world' },
        tools:   [],
        stop:    { reason: 'stop' }
      )
    end

    it 'returns the OpenAI Responses API shape' do
      result = described_class.format_response(pipeline_response, request_id: 'resp_abc123', model: 'gpt-4o')

      expect(result[:id]).to eq('resp_abc123')
      expect(result[:object]).to eq('response')
      expect(result[:model]).to eq('gpt-4o')
      expect(result[:status]).to eq('completed')
      expect(result[:output]).to be_an(Array)
      expect(result[:output].last[:type]).to eq('message')
      expect(result[:output].last[:content]).to eq([{ type: 'output_text', text: 'Hello world' }])
      expect(result[:usage][:input_tokens]).to eq(15)
      expect(result[:usage][:output_tokens]).to eq(25)
      expect(result[:usage][:total_tokens]).to eq(40)
    end

    it 'includes tool calls in output when present' do
      tc = double('ToolCall', id: 'call_1', name: 'search', arguments: { query: 'test' })
      response_with_tools = double(
        'PipelineResponse',
        routing: { model: 'gpt-4o' },
        tokens:  { input: 10, output: 20 },
        message: { content: 'result' },
        tools:   [tc],
        stop:    { reason: 'tool_calls' }
      )

      result = described_class.format_response(response_with_tools, request_id: 'resp_xyz', model: 'gpt-4o')
      function_calls = result[:output].select { |o| o[:type] == 'function_call' }
      expect(function_calls.size).to eq(1)
      expect(function_calls.first[:name]).to eq('search')
    end
  end

  describe '.stream_response' do
    it 'emits response.completed usage from object-backed token counts' do
      pipeline_response = double(
        'PipelineResponse',
        routing: { model: 'gpt-4o' },
        tokens:  Legion::LLM::Usage.new(input_tokens: 12, output_tokens: 7)
      )
      executor = double('Executor')
      out = +''

      allow(executor).to receive(:stream_preflight!).and_return(nil)
      allow(executor).to receive(:call_stream) do |&block|
        block.call('Hello ')
        block.call('world')
        pipeline_response
      end

      described_class.stream_response(out, executor, request_id: 'resp_stream', model: 'fallback-model')

      completed_payload = out[/event: response.completed\ndata: (.+)\n\n/, 1]
      completed = Legion::JSON.parse(completed_payload, symbolize_names: true)

      expect(completed[:response][:id]).to eq('resp_stream')
      expect(completed[:response][:model]).to eq('gpt-4o')
      expect(completed[:response][:usage]).to eq(
        input_tokens:  12,
        output_tokens: 7,
        total_tokens:  19
      )
    end

    it 'uses Responses upstream executor path when an upstream body is provided' do
      pipeline_response = double(
        'PipelineResponse',
        routing: { model: 'gpt-5.4' },
        tokens:  { input_tokens: 8, output_tokens: 5 }
      )
      executor = double('Executor')
      out = +''

      allow(executor).to receive(:respond_to?).with(:call_responses).and_return(true)
      allow(executor).to receive(:call_responses) do |body:, stream:, &block|
        block.call('hi')
        expect(body).to eq(input: 'say hi', stream: true)
        expect(stream).to be(true)
        pipeline_response
      end

      described_class.stream_response(
        out,
        executor,
        request_id:    'resp_stream',
        model:         'gpt-5.4',
        upstream_body: { input: 'say hi', stream: true }
      )

      expect(executor).to have_received(:call_responses)
      expect(out).to include('event: response.completed')
    end

    it 'streams function_call output items from the final pipeline response' do
      tool_call = double('ToolCall', id: 'call_git_1', name: 'git', arguments: { command: 'status' })
      pipeline_response = double(
        'PipelineResponse',
        routing: { model: 'gpt-4o' },
        tokens:  { input_tokens: 8, output_tokens: 5 },
        tools:   [tool_call]
      )
      executor = double('Executor')
      out = +''

      allow(executor).to receive(:stream_preflight!).and_return(nil)
      allow(executor).to receive(:call_stream).and_return(pipeline_response)

      described_class.stream_response(out, executor, request_id: 'resp_stream', model: 'fallback-model')

      expect(out).to include('event: response.output_item.added')
      expect(out).to include('event: response.function_call_arguments.delta')
      expect(out).to include('event: response.function_call_arguments.done')
      expect(out).to include('"type":"function_call"')
      expect(out).to include('"call_id":"call_git_1"')
      expect(out).to include('"name":"git"')
      expect(out).to include('"arguments":"{\\"command\\":\\"status\\"}"')

      completed_payload = out[/event: response.completed\ndata: (.+)\n\n/, 1]
      completed = Legion::JSON.parse(completed_payload, symbolize_names: true)
      function_calls = completed[:response][:output].select { |item| item[:type] == 'function_call' }

      expect(function_calls.size).to eq(1)
      expect(function_calls.first[:call_id]).to eq('call_git_1')
    end
  end

  describe '.extract_token' do
    it 'extracts from hash with symbol keys' do
      expect(described_class.extract_token({ input: 42, output: 10 }, :input)).to eq(42)
    end

    it 'extracts from objects responding to methods' do
      usage = Struct.new(:input_tokens, :output_tokens).new(100, 50)
      expect(described_class.extract_token(usage, :input)).to eq(100)
    end

    it 'extracts object-backed counts when explicit token keys are requested' do
      usage = Legion::LLM::Usage.new(input_tokens: 100, output_tokens: 50)

      expect(described_class.extract_token(usage, :input_tokens)).to eq(100)
      expect(described_class.extract_token(usage, :output_tokens)).to eq(50)
    end

    it 'returns 0 for nil tokens' do
      expect(described_class.extract_token(nil, :input)).to eq(0)
    end
  end
end
