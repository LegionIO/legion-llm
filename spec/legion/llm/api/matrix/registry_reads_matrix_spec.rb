# frozen_string_literal: true

require_relative 'matrix_helper'

RSpec.describe '[matrix] one registry view per request', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
    Legion::Settings::Extensions.reset!
    Legion::Settings[:llm][:rag][:enabled] = false
    [
      ['probe_zeta', true, ['quartz']],
      ['probe_always', false, []],
      ['probe_alpha', true, %w[quartz nebula]],
      ['probe_hint', true, []]
    ].each do |name, deferred, words|
      Legion::Settings::Extensions.register_tool(name, {
                                                   deferred: deferred, trigger_words: words, extension: 'probe', runner: 'jobs', function: 'inspect',
        input_schema: { type: 'object', properties: {} }
                                                 })
    end
    allow_any_instance_of(Legion::LLM::Inference::Executor).to receive(:step_gaia_advisory) do |executor|
      executor.enrichments['gaia:advisory'] = { data: { tool_hint: ['probe_hint'] } }
    end
  end

  after do
    Legion::LLM::Inference::Background.shutdown
    Legion::LLM::Inference::Background.start
    Legion::Settings::Extensions.reset!
    MatrixHelper.restore_started_state!
  end

  %i[chat responses messages].each do |dialect|
    [false, true].each do |streaming|
      it "preserves tool definitions and ownership through #{dialect}, stream=#{streaming}, with one registry read" do
        allow(Legion::Settings::Extensions).to receive(:tools).and_call_original
        allow(Legion::Settings::Extensions).to receive(:filter_tools).and_call_original
        body = { model: 'fake-default', stream: streaming }
        path = case dialect
               when :responses
                 body.merge!(input: 'quartz nebula', max_output_tokens: 2048)
                 '/v1/responses'
               when :chat
                 body.merge!(messages: [{ role: 'user', content: 'quartz nebula' }], max_tokens: 2048)
                 '/v1/chat/completions'
               when :messages
                 body.merge!(messages: [{ role: 'user', content: 'quartz nebula' }], max_tokens: 2048)
                 '/v1/messages'
               end
        FakeProvider.with_scenario(streaming ? :stream_text : :text) do
          post path, Legion::JSON.dump(body), 'CONTENT_TYPE' => 'application/json'
        end
        expect(last_response.status).to eq(200), last_response.body
        expect(FakeProvider.calls.size).to eq(1)
        tools = FakeProvider.calls.last[:tools].values.select { |tool| tool.name.start_with?('probe_') }
        expect(tools.map(&:name)).to eq(%w[probe_always probe_hint probe_zeta probe_alpha])
        expect(tools).to all(be_a(Legion::Extensions::Llm::Canonical::ToolDefinition))
        expect(tools.map(&:source)).to all(include(type: :extension, extension: 'probe', runner: 'jobs', function: 'inspect'))
        expect(Legion::Settings::Extensions).to have_received(:tools).once
        expect(Legion::Settings::Extensions).not_to have_received(:filter_tools)
      end
    end
  end
end
