# frozen_string_literal: true

# RULES.md rule 13 (N x N ALWAYS converges through Canonical): a two-part
# system prompt must reach the PROVIDER as the identical "\n\n"-joined string
# from every client dialect, and cache_control annotations must never leak
# block structure — or Ruby inspect output of a block array — into the
# system prompt.
#
# This is the in-process mirror of the client_translators equivalence spec,
# at the layer that gates commits: it proves the FULL route -> client
# translator -> executor -> adapter path, not just parse_request. The
# pre-fix failures were: Chat/Responses joined with "" ("Rule ARule B"),
# the Anthropic cached branch returned a block Array that the adapter
# stringified into inspect garbage, and Responses system items with array
# content were inspect-garbage even without cache_control.

require_relative 'matrix_helper'

RSpec.describe '[matrix] two-part system prompt x all client dialects', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
  end

  after do
    MatrixHelper.restore_started_state!
  end

  # The provider receives system folded into a leading role:system message
  # by the dispatch adapter; read that message's text.
  def provider_system_text(call)
    call[:messages].each do |m|
      role = (m.respond_to?(:role) ? m.role : (m[:role] || m['role'])).to_s
      next unless role == 'system'

      return (m.respond_to?(:content) ? m.content : (m[:content] || m['content'])).to_s
    end
    nil
  end

  describe '/v1/messages (Anthropic dialect)' do
    it 'sends two system blocks to the provider as one "\\n\\n"-joined string' do
      FakeProvider.with_scenario(:text) do
        post '/v1/messages',
             Legion::JSON.dump({
                                 model:      'fake-default',
                                 max_tokens: 64,
                                 system:     [{ type: 'text', text: 'Rule A' }, { type: 'text', text: 'Rule B' }],
                                 messages:   [{ role: 'user', content: 'hi' }]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"
      expect(provider_system_text(FakeProvider.calls.last)).to eq("Rule A\n\nRule B")
    end

    it 'sends cached system blocks as the same string — no block structure, no inspect output' do
      FakeProvider.with_scenario(:text) do
        post '/v1/messages',
             Legion::JSON.dump({
                                 model:      'fake-default',
                                 max_tokens: 64,
                                 system:     [{ type: 'text', text: 'Rule A', cache_control: { type: 'ephemeral' } },
                                              { type: 'text', text: 'Rule B' }],
                                 messages:   [{ role: 'user', content: 'hi' }]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"
      expect(provider_system_text(FakeProvider.calls.last)).to eq("Rule A\n\nRule B")
    end
  end

  describe '/v1/chat/completions (OpenAI Chat dialect)' do
    it 'sends a two-part system message to the provider as one "\\n\\n"-joined string' do
      FakeProvider.with_scenario(:text) do
        post '/v1/chat/completions',
             Legion::JSON.dump({
                                 model:    'fake-default',
                                 messages: [
                                   { role:    'system',
                                     content: [{ type: 'text', text: 'Rule A' }, { type: 'text', text: 'Rule B' }] },
                                   { role: 'user', content: 'hi' }
                                 ]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"
      expect(provider_system_text(FakeProvider.calls.last)).to eq("Rule A\n\nRule B")
    end

    it 'sends a cached two-part system message as the same string' do
      FakeProvider.with_scenario(:text) do
        post '/v1/chat/completions',
             Legion::JSON.dump({
                                 model:    'fake-default',
                                 messages: [
                                   { role:    'system',
                                     content: [{ type: 'text', text: 'Rule A', cache_control: { type: 'ephemeral' } },
                                               { type: 'text', text: 'Rule B' }] },
                                   { role: 'user', content: 'hi' }
                                 ]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"
      expect(provider_system_text(FakeProvider.calls.last)).to eq("Rule A\n\nRule B")
    end
  end

  describe '/v1/responses (OpenAI Responses dialect)' do
    it 'sends two-part instructions to the provider as the same string' do
      FakeProvider.with_scenario(:text) do
        post '/v1/responses',
             Legion::JSON.dump({
                                 model:        'fake-default',
                                 instructions: "Rule A\n\nRule B",
                                 input:        [{ role: 'user', content: 'hi' }]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"
      expect(provider_system_text(FakeProvider.calls.last)).to eq("Rule A\n\nRule B")
    end

    it 'sends a two-part system input item to the provider as one "\\n\\n"-joined string' do
      FakeProvider.with_scenario(:text) do
        post '/v1/responses',
             Legion::JSON.dump({
                                 model: 'fake-default',
                                 input: [
                                   { role:    'system',
                                     content: [{ type: 'input_text', text: 'Rule A' }, { type: 'input_text', text: 'Rule B' }] },
                                   { role: 'user', content: 'hi' }
                                 ]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"
      expect(provider_system_text(FakeProvider.calls.last)).to eq("Rule A\n\nRule B")
    end

    it 'sends a cached two-part system input item as the same string — no inspect output' do
      FakeProvider.with_scenario(:text) do
        post '/v1/responses',
             Legion::JSON.dump({
                                 model: 'fake-default',
                                 input: [
                                   { role:    'system',
                                     content: [{ type: 'input_text', text: 'Rule A', cache_control: { type: 'ephemeral' } },
                                               { type: 'input_text', text: 'Rule B' }] },
                                   { role: 'user', content: 'hi' }
                                 ]
                               }),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}: #{last_response.body}"
      expect(provider_system_text(FakeProvider.calls.last)).to eq("Rule A\n\nRule B")
    end
  end
end
