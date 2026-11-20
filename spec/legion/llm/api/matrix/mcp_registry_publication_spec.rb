# frozen_string_literal: true

require_relative 'matrix_helper'
require 'legion/mcp/client'

RSpec.describe '[matrix] MCP publication after trigger matching', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }
  let(:schema) { { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } }
  let(:remote_tool) { { name: 'late_remote', description: 'Current remote tool', input_schema: schema } }
  let(:connection) { instance_double(Legion::MCP::Client::Connection, tools: remote_tools) }

  before do
    MatrixHelper.configure_for_fake!
    Legion::Settings::Extensions.reset!
    Legion::Settings[:llm][:rag][:enabled] = false
    allow(Legion::MCP::Client::ServerRegistry).to receive(:healthy_servers).and_return('probe' => {})
    allow(Legion::MCP::Client::Pool).to receive(:connection_for).with('probe').and_return(connection)
    # Pool.all_tools remains real: it publishes the connection's tools into the
    # framework registry after trigger matching has already captured its view.
  end

  after do
    Legion::LLM::Inference::Background.shutdown
    Legion::LLM::Inference::Background.start
    Legion::MCP::Client::ServerRegistry.deregister('probe')
    Legion::Settings::Extensions.reset!
    MatrixHelper.restore_started_state!
  end

  %i[new replacement partial_failure].each do |publication|
    context "with #{publication} publication" do
      # The real pool commits the first entry, then handles the invalid second
      # entry by marking the server unhealthy and returning an empty result.
      let(:remote_tools) { publication == :partial_failure ? [remote_tool, nil] : [remote_tool] }

      before do
        if publication == :replacement
          Legion::Settings::Extensions.register_tool('late_remote', {
                                                       description: 'Old remote tool', deferred: false,
            input_schema: { type: 'object', properties: { obsolete: { type: 'boolean' } } },
            extension: 'mcp:probe', dispatch_type: :mcp_remote
                                                     })
        end
      end

      %i[chat responses messages].each do |dialect|
        [false, true].each do |streaming|
          it "uses the newly published tool definition in #{dialect}, stream=#{streaming}" do
            allow(Legion::Settings::Extensions).to receive(:tools).and_call_original
            body = { model: 'fake-default', stream: streaming }
            path = case dialect
                   when :responses
                     body.merge!(input: 'Continue the next task.', max_output_tokens: 2048)
                     '/v1/responses'
                   when :chat
                     body.merge!(messages: [{ role: 'user', content: 'Continue the next task.' }], max_tokens: 2048)
                     '/v1/chat/completions'
                   when :messages
                     body.merge!(messages: [{ role: 'user', content: 'Continue the next task.' }], max_tokens: 2048)
                     '/v1/messages'
                   end

            FakeProvider.with_scenario(streaming ? :stream_text : :text) do
              post path, Legion::JSON.dump(body), 'CONTENT_TYPE' => 'application/json'
            end

            expect(last_response.status).to eq(200), last_response.body
            registered = Legion::Settings::Extensions.find_tool('late_remote')
            expect(registered[:input_schema]).to eq(schema)
            tool = FakeProvider.calls.last[:tools][:late_remote]
            expect(tool).to be_a(Legion::Extensions::Llm::Canonical::ToolDefinition)
            expect(tool.parameters).to eq(schema)
            expect(tool.description).to eq('Current remote tool')
            expect(tool.source[:extension]).to eq('mcp:probe')
            expect(Legion::Settings::Extensions).to have_received(:tools).twice
          end
        end
      end
    end
  end
end
