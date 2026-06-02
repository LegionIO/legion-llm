# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/namespaces/openai/models'
require 'legion/llm/api/namespaces/openai/responses'

# Simulates the exact request sequence Codex CLI makes when configured with:
#   wire_api = "responses"
#   base_url = "http://localhost:4567/v1"
#
# Codex CLI flow:
#   1. GET /v1/models  — validate model exists
#   2. POST /v1/responses { stream: true }  — primary inference
RSpec.describe 'Codex CLI conformance', :integration do
  include Rack::Test::Methods

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      register Sinatra::Namespace
      helpers Legion::Logging::Helper
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Models
      register Legion::LLM::API::Namespaces::OpenAI::Responses
    end
  end

  let(:pipeline_response) do
    double('Response',
           routing: { model: 'legionio' },
           tokens:  { input_tokens: 12, output_tokens: 38 },
           tools:   [])
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM::Inventory).to receive(:offerings).and_return([
                                                                      { model: 'legionio', provider_family: 'legion', type: :inference }
                                                                    ])
    allow(Legion::LLM::Inference::Request).to receive(:build).and_return(double('Request'))
    allow(Legion::LLM::Inference::Executor).to receive(:new).and_return(
      double('Executor').tap do |ex|
        allow(ex).to receive(:call_stream) do |&block|
          block.call(double('Chunk', content: 'def hello; end'))
          pipeline_response
        end
        allow(ex).to receive(:call_responses) do |**, &block|
          block.call(double('Chunk', content: 'def hello; end'))
          pipeline_response
        end
        allow(ex).to receive(:respond_to?).with(:call_responses).and_return(true)
      end
    )
    Legion::Settings[:llm][:default_model] = 'legionio'
  end

  it 'Step 1: GET /v1/models returns legionio in the model list' do
    get '/v1/models', {}, { 'HTTP_AUTHORIZATION' => 'Bearer any-key' }
    expect(last_response.status).to eq(200)
    body = Legion::JSON.load(last_response.body)
    expect(body[:object]).to eq('list')
    ids = body[:data].map { |m| m[:id] }
    expect(ids).to include('legionio')
  end

  it 'Step 2: POST /v1/responses with stream: true emits well-formed typed SSE' do
    post '/v1/responses',
         Legion::JSON.dump({
                             model:        'legionio',
                             input:        'Write a hello world function in Ruby',
                             stream:       true,
                             instructions: 'You are a Ruby expert.'
                           }),
         'CONTENT_TYPE'       => 'application/json',
         'HTTP_AUTHORIZATION' => 'Bearer any-key'

    expect(last_response.status).to eq(200)
    expect(last_response.content_type).to include('text/event-stream')

    body = last_response.body

    # All required Codex CLI streaming events must be present
    expect(body).to include('event: response.created')
    expect(body).to include('event: response.in_progress')
    expect(body).to include('event: response.output_item.added')
    expect(body).to include('event: response.content_part.added')
    expect(body).to include('event: response.output_text.delta')
    expect(body).to include('event: response.output_text.done')
    expect(body).to include('event: response.content_part.done')
    expect(body).to include('event: response.output_item.done')
    expect(body).to include('event: response.completed')

    # Must NOT emit data: [DONE] (that's chat completions format)
    expect(body).not_to include('data: [DONE]')

    # response.completed must contain usage
    completed_payload = body[/event: response\.completed\ndata: (.+)\n\n/, 1]
    expect(completed_payload).not_to be_nil
    completed = Legion::JSON.load(completed_payload)
    expect(completed[:response][:id]).to start_with('resp_')
    expect(completed[:response][:status]).to eq('completed')
    expect(completed[:response][:usage][:input_tokens]).to eq(12)
    expect(completed[:response][:usage][:output_tokens]).to eq(38)
    expect(completed[:response][:usage][:total_tokens]).to eq(50)

    # Delta must contain the streamed content
    delta_payload = body[/event: response\.output_text\.delta\ndata: (.+)\n\n/, 1]
    expect(delta_payload).not_to be_nil
    delta = Legion::JSON.load(delta_payload)
    expect(delta[:delta]).to eq('def hello; end')

    # sequence_number must be monotonically increasing
    seq_numbers = body.scan(/"sequence_number":(\d+)/).flatten.map(&:to_i)
    expect(seq_numbers).to eq(seq_numbers.sort)
    expect(seq_numbers.uniq.size).to be > 4
  end
end
