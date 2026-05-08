# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/transport/exchanges/audit'
require 'legion/llm/transport/messages/prompt_event'

RSpec.describe Legion::LLM::Transport::Messages::PromptEvent do
  let(:base_opts) do
    {
      request_type:    'chat',
      provider:        'ollama',
      model:           'qwen3.5:27b',
      tier:            'fleet',
      message_context: { conversation_id: 'conv_1' },
      classification:  { level: 'internal', contains_phi: true, jurisdictions: %w[us eu], retention: 'permanent' },
      caller:          { requested_by: { identity: 'user:alice', type: 'user' } }
    }
  end

  def build(**)
    described_class.new(**base_opts, **)
  end

  def stub_process_identity(identity: 'matt@example.com', kind: :human, source: :system)
    stub_const('Legion::Identity', Module.new) unless defined?(Legion::Identity)
    process = Module.new do
      class << self
        attr_accessor :canonical_name_value, :kind_value, :source_value

        def canonical_name = @canonical_name_value
        def kind = @kind_value
        def source = @source_value
      end
    end
    process.canonical_name_value = identity
    process.kind_value = kind
    process.source_value = source

    stub_const('Legion::Identity::Process', process)
  end

  describe '#type' do
    it 'returns llm.audit.prompt' do
      expect(build.type).to eq('llm.audit.prompt')
    end
  end

  describe '#routing_key' do
    it 'builds from request_type' do
      expect(build.routing_key).to eq('audit.prompt.chat')
    end
  end

  describe '#encrypt?' do
    it 'returns false by default' do
      expect(build.encrypt?).to eq(false)
    end

    it 'returns true when encrypt_audit is enabled' do
      Legion::Settings[:llm][:compliance] = Legion::Settings[:llm][:compliance].merge(encrypt_audit: true)
      expect(build.encrypt?).to eq(true)
    end
  end

  describe '#message_id' do
    it 'has audit_prompt prefix' do
      expect(build.message_id).to match(/\Aaudit_prompt_/)
    end
  end

  describe '#headers' do
    let(:headers) { build.headers }

    before do
      stub_process_identity
    end

    it 'sets classification header' do
      expect(headers['x-legion-classification']).to eq('internal')
    end

    it 'sets phi header' do
      expect(headers['x-legion-contains-phi']).to eq('true')
    end

    it 'sets jurisdiction header as comma-joined' do
      expect(headers['x-legion-jurisdictions']).to eq('us,eu')
    end

    it 'sets publisher identity without exposing a legacy caller identity header' do
      expect(headers['x-legion-identity']).to eq('matt@example.com')
      expect(headers).not_to have_key('x-legion-caller-identity')
    end

    it 'preserves publisher caller type and carries request caller type separately' do
      expect(headers['x-legion-caller-type']).to eq('human')
      expect(headers['x-legion-request-caller-type']).to eq('user')
    end

    it 'sets retention' do
      expect(headers['x-legion-retention']).to eq('permanent')
    end

    it 'sets tier' do
      expect(headers['x-legion-llm-tier']).to eq('fleet')
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
      msg = build
      msg.encode_message
      expect(msg.headers['iv']).to eq(fake_iv)
    end

    it 'returns gcm-prefixed ciphertext from encode_message' do
      msg = build
      payload = msg.encode_message
      expect(payload).to start_with('gcm:')
      expect(payload).to eq(fake_ciphertext)
    end

    it 'sets content_encoding to encrypted/cs' do
      msg = build
      msg.encode_message
      envelope = msg.publish_envelope_options(base_opts)
      expect(envelope[:content_encoding]).to eq('encrypted/cs')
    end

    it 'does not include iv header before encode_message' do
      msg = build
      expect(msg.headers).not_to have_key('iv')
    end
  end

  describe 'unencrypted audit' do
    it 'does not include iv header' do
      msg = build
      msg.encode_message
      expect(msg.headers).not_to have_key('iv')
    end

    it 'returns cleartext JSON from encode_message' do
      msg = build
      payload = msg.encode_message
      expect(payload).not_to start_with('gcm:')
      parsed = Legion::JSON.load(payload)
      expect(parsed[:request_type]).to eq('chat')
    end

    it 'sets content_encoding to identity' do
      msg = build
      msg.encode_message
      envelope = msg.publish_envelope_options(base_opts)
      expect(envelope[:content_encoding]).to eq('identity')
    end
  end
end
