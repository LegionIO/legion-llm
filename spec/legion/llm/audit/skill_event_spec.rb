# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/transport/exchanges/audit'
require 'legion/llm/transport/messages/skill_event'

RSpec.describe Legion::LLM::Transport::Messages::SkillEvent do
  let(:event) do
    described_class.new(
      skill_name: 'brainstorming', namespace: 'superpowers',
      step_name: 'explore_context', gate: :await_user_input,
      status: :completed, duration_ms: 42,
      classification: { level: 'internal', contains_phi: false }
    )
  end

  describe '#routing_key' do
    it 'uses audit.skill.namespace.name format' do
      expect(event.routing_key).to eq('audit.skill.superpowers.brainstorming')
    end
  end

  describe '#encrypt?' do
    it 'returns false by default' do
      expect(event.encrypt?).to be false
    end

    it 'returns true when encrypt_audit is enabled' do
      Legion::Settings[:llm][:compliance] = Legion::Settings[:llm][:compliance].merge(encrypt_audit: true)
      expect(event.encrypt?).to be true
    end
  end

  describe '#headers' do
    subject(:headers) { event.headers }

    it 'includes skill-specific headers' do
      expect(headers['x-legion-skill-name']).to eq('brainstorming')
      expect(headers['x-legion-skill-namespace']).to eq('superpowers')
      expect(headers['x-legion-skill-step']).to eq('explore_context')
      expect(headers['x-legion-skill-gate']).to eq('await_user_input')
      expect(headers['x-legion-skill-status']).to eq('completed')
    end

    it 'includes classification headers' do
      expect(headers['x-legion-classification']).to eq('internal')
      expect(headers['x-legion-contains-phi']).to eq('false')
    end
  end

  describe 'encrypted audit' do
    let(:fake_iv) { Base64.strict_encode64(SecureRandom.random_bytes(12)) }
    let(:fake_ciphertext) { "gcm:#{Base64.strict_encode64('encrypted')}:#{Base64.strict_encode64('tag')}" }

    before do
      Legion::Settings[:llm][:compliance] = Legion::Settings[:llm][:compliance].merge(encrypt_audit: true)
      stub_const('Legion::Crypt', Module.new)
      allow(Legion::Crypt).to receive(:encrypt).and_return(
        enciphered_message: fake_ciphertext,
        iv:                 fake_iv
      )
    end

    it 'includes iv header after encode_message' do
      event.encode_message
      expect(event.headers['iv']).to eq(fake_iv)
    end

    it 'returns gcm-prefixed ciphertext from encode_message' do
      payload = event.encode_message
      expect(payload).to start_with('gcm:')
    end

    it 'sets content_encoding to encrypted/cs' do
      event.encode_message
      envelope = event.publish_envelope_options({})
      expect(envelope[:content_encoding]).to eq('encrypted/cs')
    end
  end

  describe 'unencrypted audit' do
    it 'does not include iv header' do
      event.encode_message
      expect(event.headers).not_to have_key('iv')
    end

    it 'returns cleartext JSON from encode_message' do
      payload = event.encode_message
      expect(payload).not_to start_with('gcm:')
    end
  end
end
