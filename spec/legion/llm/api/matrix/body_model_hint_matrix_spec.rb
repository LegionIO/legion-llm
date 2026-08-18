# frozen_string_literal: true

# SSOT v3 D19 matrix scenario: the body model hint must be honored end-to-end
# through the mounted /v1/chat/completions route (parse_request ->
# build_inference_request -> Request.build -> BodyModelHintPolicy ->
# RequestRequirements -> lane selection). The join spec
# (spec/legion/llm/api/client_translators/body_model_hint_join_spec.rb) pins
# the translator seam; this proves the full HTTP surface selects the hinted
# lane. A second fake instance makes the pin observable: without a model pin
# both fake lanes are eligible, with the hint honored exactly one is.

require_relative 'matrix_helper'

RSpec.describe '[matrix] /v1/chat/completions x body-model hint', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }
  let(:alt_model) { 'fake-alt' }

  before do
    MatrixHelper.configure_for_fake!
    SsotV3SnapshotFactory.activate(
      provider_family: 'fake',
      instance_id:     'alt',
      drafts:          [
        SsotV3SnapshotFactory.offering_draft(
          model:        alt_model,
          tier:         :local,
          supported:    %i[chat stream_chat count_tokens],
          capabilities: { streaming: :supported, tools: :supported },
          context:      200_000,
          max_output:   16_384
        )
      ],
      callable:        FakeProvider.adapter
    )
  end

  after do
    MatrixHelper.restore_started_state!
  end

  def post_chat(**body)
    post '/v1/chat/completions', Legion::JSON.dump(body), 'CONTENT_TYPE' => 'application/json'
    last_response
  end

  def with_body_hints(allow:)
    Legion::Settings[:llm][:routing][:allow_body_routing_hints] = allow
    Legion::LLM::Router::SettingsState.reset!
    yield
  ensure
    Legion::Settings[:llm][:routing][:allow_body_routing_hints] = false
    Legion::LLM::Router::SettingsState.reset!
  end

  describe 'scenario: hint honored (flag on, two eligible lanes)' do
    it 'selects the lane of the body model when hints are enabled' do
      with_body_hints(allow: true) do
        FakeProvider.with_scenario(:text) do
          resp = post_chat(model: alt_model, messages: [{ role: 'user', content: 'hi' }])
          expect(resp.status).to eq(200)
          expect(resp.headers['X-Legion-Model']).to eq(alt_model)
        end
      end
    end

    it 'selects the other lane for a different body model (pin follows the hint)' do
      with_body_hints(allow: true) do
        FakeProvider.with_scenario(:text) do
          resp = post_chat(model: MatrixHelper::FAKE_MODEL, messages: [{ role: 'user', content: 'hi' }])
          expect(resp.status).to eq(200)
          expect(resp.headers['X-Legion-Model']).to eq(MatrixHelper::FAKE_MODEL)
        end
      end
    end

    # v2 parity (v2 executor/routing.rb model_discovery_miss: model=nil,
    # auto_route=true): a body model that no lane holds is not a caller error —
    # the hint pin is cleared and normal weighted selection picks a lane.
    it 'falls back to weighted selection (200, a lane) when the honored hint matches no lane' do
      with_body_hints(allow: true) do
        FakeProvider.with_scenario(:text) do
          resp = post_chat(model: 'no-such-model', messages: [{ role: 'user', content: 'hi' }])
          expect(resp.status).to eq(200)
          expect([MatrixHelper::FAKE_MODEL, alt_model]).to include(resp.headers['X-Legion-Model'])
        end
      end
    end
  end

  describe 'scenario: hints disabled (default)' do
    it 'does not pin the body model — selection stays free across eligible lanes' do
      FakeProvider.with_scenario(:text) do
        resp = post_chat(model: alt_model, messages: [{ role: 'user', content: 'hi' }])
        expect(resp.status).to eq(200)
        expect([MatrixHelper::FAKE_MODEL, alt_model]).to include(resp.headers['X-Legion-Model'])
      end
    end
  end
end
