# frozen_string_literal: true

require_relative 'matrix_helper'
require 'legion/extensions/llm/vllm/translator'
require 'legion/extensions/llm/openai/translator'
require 'legion/extensions/llm/bedrock/translator'

RSpec.describe '[matrix] configured output budgets', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
  end
  after { MatrixHelper.restore_started_state! }

  [
    ['/v1/messages', :max_tokens, { messages: [{ role: 'user', content: 'Hello.' }] }],
    ['/v1/chat/completions', :max_tokens, { messages: [{ role: 'user', content: 'Hello.' }] }],
    ['/v1/chat/completions', :max_completion_tokens, { messages: [{ role: 'user', content: 'Hello.' }] }],
    ['/v1/responses', :max_output_tokens, { input: 'Hello.' }]
  ].each do |path, limit_key, payload|
    [false, true].each do |stream|
      [[nil, 12_345], [128, 12_345], [nil, nil]].each do |explicit_limit, configured_limit|
        it "uses one budget for #{path} #{limit_key}=#{explicit_limit.inspect}, configured=#{configured_limit.inspect}, stream=#{stream}" do
          Legion::Settings[:llm][:max_output_tokens] = configured_limit if configured_limit
          expected_limit = explicit_limit || configured_limit || 64_000
          routing_limits = []
          dispatches = []
          allow(Legion::LLM::Router).to receive(:new).and_wrap_original do |original, **args|
            original.call(**args).tap { |requirements| routing_limits << requirements.required_output_tokens }
          end
          operation = stream ? :stream_chat : :chat
          allow(FakeProvider.adapter).to receive(operation).and_wrap_original do |original, messages, **options, &block|
            dispatches << Legion::Extensions::Llm::Canonical::Request.build(
              messages: messages, params: options.fetch(:params), stream: stream,
              metadata: { model: MatrixHelper::FAKE_MODEL }
            )
            original.call(messages, **options, &block)
          end

          body = payload.merge(model: MatrixHelper::FAKE_MODEL, stream: stream)
          body[limit_key] = explicit_limit if explicit_limit
          FakeProvider.with_scenario(stream ? :stream_text : :text) do
            post path, Legion::JSON.dump(body), 'CONTENT_TYPE' => 'application/json'
          end

          # Messages requires a client max_tokens on the wire. Preserve that
          # validation; the omitted-limit default applies to accepted requests.
          if path == '/v1/messages' && explicit_limit.nil?
            expect(last_response.status).to eq(400)
            expect(routing_limits).to be_empty
            expect(dispatches).to be_empty
            next
          end

          expect(last_response.status).to eq(200)
          expect(routing_limits).not_to be_empty
          expect(routing_limits).to all(eq(expected_limit))
          expect(dispatches).not_to be_empty
          dispatches.each do |request|
            expect(request.params.max_tokens).to eq(expected_limit)
            expect(Legion::Extensions::Llm::Vllm::Translator.new.render_request(request)[:max_tokens]).to eq(expected_limit)
            expect(Legion::Extensions::Llm::Openai::Translator.new.render_request(request)[:max_tokens]).to eq(expected_limit)
            bedrock = Legion::Extensions::Llm::Bedrock::Translator.new.render_request(request, target: :converse)
            expect(bedrock.dig(:inference_config, :max_tokens)).to eq(expected_limit)
          end
        end
      end
    end
  end
end
