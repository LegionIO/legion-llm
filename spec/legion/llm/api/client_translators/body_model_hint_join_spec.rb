# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_chat'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/router/request_requirements'

# SSOT v3 D19 join point: the mounted API routes drive
# translator.parse_request -> translator.build_inference_request ->
# Inference::Request.build, and the body model parsed by parse_request must
# reach BodyModelHintPolicy through that join. The policy/request_requirements/
# executor specs each pass client_model straight to Request.build, so none of
# them cross the translator seam this spec covers.
RSpec.describe 'client translator body-model hint join' do
  let(:header_env) { { 'HTTP_X_LEGION_MODEL' => 'gemma4' } }
  let(:body_model) { 'gpt-5.5' }

  shared_examples 'the body-model hint join' do
    def build_inference_request(request_body, env = {})
      canonical = translator.parse_request(request_body, env)
      translator.build_inference_request(
        canonical, request_id: 'req_join', server_caller: { source: 'spec' }
      )
    end

    def build_reqs(request)
      Legion::LLM::Router::RequestRequirements.build(
        request: request, operation: :chat, required_capabilities: [],
        estimated_input_bound: 100, required_output_tokens: 50
      )
    end

    def with_body_hint_settings(allow:, whitelist: [], blacklist: [])
      settings = Legion::Settings[:llm][:routing]
      settings[:allow_body_routing_hints] = allow
      settings[:body_model_hint_whitelist] = whitelist
      settings[:body_model_hint_blacklist] = blacklist
      Legion::LLM::Router::SettingsState.reset!
      yield
    ensure
      settings = Legion::Settings[:llm][:routing]
      settings[:allow_body_routing_hints] = false
      settings[:body_model_hint_whitelist] = []
      settings[:body_model_hint_blacklist] = []
      Legion::LLM::Router::SettingsState.reset!
    end

    it 'honors the body model as a routing pin when hints are enabled and no trusted pin is present' do
      with_body_hint_settings(allow: true) do
        request = build_inference_request(body)
        decision = request.body_model_hint_decision

        expect(decision.disposition).to eq(:honored)
        expect(decision.requested_model).to eq(body_model)
        expect(decision.model_constraint).to eq(body_model)
        expect(build_reqs(request).model_pin).to eq(body_model)
      end
    end

    it 'lets the X-Legion-Model trusted pin supersede the body model' do
      with_body_hint_settings(allow: true) do
        request = build_inference_request(body, header_env)
        decision = request.body_model_hint_decision

        expect(decision.disposition).to eq(:superseded_by_explicit_model)
        expect(decision.requested_model).to eq(body_model)
        expect(decision.model_constraint).to be_nil
        reqs = build_reqs(request)
        expect(reqs.model_pin).to eq(header_env['HTTP_X_LEGION_MODEL'])
        expect(reqs.body_model_hint_decision.disposition).to eq(:superseded_by_explicit_model)
      end
    end

    it 'ignores the body model when hints are disabled (the default)' do
      request = build_inference_request(body)
      decision = request.body_model_hint_decision

      expect(decision.disposition).to eq(:ignored_disabled)
      expect(decision.requested_model).to eq(body_model)
      expect(build_reqs(request).model_pin).to be_nil
    end

    it 'ignores a body model that the nonempty whitelist does not cover (no pin, no 400)' do
      with_body_hint_settings(allow: true, whitelist: %w[claude]) do
        request = build_inference_request(body)
        decision = request.body_model_hint_decision

        expect(decision.disposition).to eq(:ignored_not_whitelisted)
        expect(decision.model_constraint).to be_nil
        expect(build_reqs(request).model_pin).to be_nil
      end
    end

    it 'ignores a body model that the blacklist matches' do
      with_body_hint_settings(allow: true, blacklist: %w[gpt]) do
        request = build_inference_request(body)
        decision = request.body_model_hint_decision

        expect(decision.disposition).to eq(:ignored_blacklisted)
        expect(decision.matched_blacklist).to eq('gpt')
        expect(decision.model_constraint).to be_nil
        expect(build_reqs(request).model_pin).to be_nil
      end
    end

    it 'treats an auto-routing alias body model as you-pick intent, never a pin' do
      request = build_inference_request(auto_body)
      decision = request.body_model_hint_decision

      expect(decision.disposition).to eq(:auto)
      expect(decision.requested_model).to eq('legionio')
      expect(build_reqs(request).model_pin).to be_nil
    end
  end

  describe Legion::LLM::API::ClientTranslators::OpenAIChat do
    let(:translator) { described_class.new }
    let(:body) { { model: body_model, messages: [{ role: 'user', content: 'hello' }] } }
    let(:auto_body) { { model: 'legionio', messages: [{ role: 'user', content: 'hello' }] } }

    include_examples 'the body-model hint join'
  end

  describe Legion::LLM::API::ClientTranslators::AnthropicMessages do
    let(:translator) { described_class.new }
    let(:body) { { model: body_model, max_tokens: 1024, messages: [{ role: 'user', content: 'hello' }] } }
    let(:auto_body) { { model: 'legionio', max_tokens: 1024, messages: [{ role: 'user', content: 'hello' }] } }

    include_examples 'the body-model hint join'
  end

  describe Legion::LLM::API::ClientTranslators::OpenAIResponses do
    let(:translator) { described_class.new }
    let(:body) { { model: body_model, input: 'hello' } }
    let(:auto_body) { { model: 'legionio', input: 'hello' } }

    include_examples 'the body-model hint join'
  end
end
