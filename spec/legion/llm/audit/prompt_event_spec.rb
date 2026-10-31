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

  describe 'whole prompt audit payload budget' do
    let(:canonical) { Legion::Extensions::Llm::Canonical }
    let(:published_bodies) { [] }
    let(:audit_exchange) { double('AuditExchange', name: 'llm.audit') }

    before do
      stub_process_identity
      Legion::Settings[:transport][:max_payload_bytes] = 1_048_576
      allow(audit_exchange).to receive(:publish) { |body, **| published_bodies << body }
    end

    def prompt_audit_event(content:, response_content: 'answer', audit: {})
      request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: content }])
      response = Legion::LLM::Inference::Response.build(
        request_id: 'req-budget', conversation_id: 'conv-budget',
        message: { role: :assistant, content: response_content },
        routing: { provider: 'test', model: 'vision', tier: 'cloud' },
        tokens: { input_tokens: 100, output_tokens: 10 }, audit: audit
      )
      Legion::LLM::Inference::AuditPublisher.build_event(request: request, response: response)
    end

    def publish_event(event)
      message = described_class.new(**Legion::LLM::Audit.attributed_event(event))
      allow(message).to receive(:exchange).and_return(audit_exchange)
      result = message.publish(return_result: true)
      expect(result[:accepted]).to be(true)
      expect(published_bodies.last.bytesize).to be <= Legion::Settings[:transport][:max_payload_bytes]
      expect(Legion::JSON.dump(message.message).bytesize).to be <= Legion::Settings[:transport][:max_payload_bytes]
      Legion::JSON.load(published_bodies.last)
    end

    it 'publishes a 1.5MB image through the real transport size gate with an explicit fingerprint' do
      data = 'A' * 1_500_000
      event = prompt_audit_event(content: canonical::ContentBlock.image(data: data, media_type: 'image/png'))
      wire = publish_event(event)

      expect(wire[:messages].first[:content][:binary_fingerprint][:sha256]).to eq(Digest::SHA256.hexdigest(data))
      expect(wire[:capture]).to include(mode: 'projected', redacted_binary_count: 1, omitted_message_count: 0)
      expect(wire).to include(request_id: 'req-budget', conversation_id: 'conv-budget')
      expect(wire[:tokens]).to include(input_tokens: 100, output_tokens: 10)
    end

    it 'compacts nine individually subthreshold images before dropping any messages and does not mutate the built event' do
      data = 'A' * 120_000
      event = prompt_audit_event(content: Array.new(9) { canonical::ContentBlock.image(data: data, media_type: 'image/png') })
      original = Legion::JSON.dump(event)
      expect(original.bytesize).to be > Legion::Settings[:transport][:max_payload_bytes]
      wire = publish_event(event)

      expect(wire[:capture]).to include(redacted_binary_count: 9, redacted_binary_bytes: 1_080_000, omitted_message_count: 0)
      expect(wire[:messages].first[:content]).to all(satisfy { |block| !block.key?(:data) })
      expect(wire[:messages].first[:content].map { |block| block[:binary_fingerprint][:bytes] }).to eq([120_000] * 9)
      expect(Legion::JSON.dump(event)).to eq(original)
    end

    it 'compacts nested canonical tool images, audio and video in the complete body' do
      data = 'A' * 120_000
      media = %i[image audio video].cycle.take(9).map do |type|
        canonical::ContentBlock.build(type: type, data: data, source_type: :base64, media_type: "#{type}/test")
      end
      event = prompt_audit_event(content: canonical::ContentBlock.tool_result(tool_use_id: 'call-1', content: media))
      wire = publish_event(event)

      expect(wire[:messages].first[:content][:text].map { |block| block[:binary_fingerprint][:media_type] })
        .to eq(%w[image/test audio/test video/test] * 3)
      expect(wire[:capture]).to include(redacted_binary_count: 9, omitted_message_count: 0)
    end

    it 'fingerprints bulky non-message content while preserving usage, routing and audit outcomes' do
      response_content = 'R' * 2_000_000
      audit = { 'custom:check' => { outcome: :success, data: 'D' * 2_000_000 } }
      event = prompt_audit_event(content: 'hello', response_content: response_content, audit: audit)
      wire = publish_event(event)

      expect(wire[:response_content]).to include(audit_omitted: true, bytes: Legion::JSON.dump(response_content).bytesize,
                                                 sha256: Digest::SHA256.hexdigest(Legion::JSON.dump(response_content)))
      expect(wire[:audit][:'custom:check']).to include(audit_omitted: true, outcome: 'success')
      expect(wire[:routing]).to include(provider: 'test', model: 'vision', tier: 'cloud')
      expect(wire[:tokens]).to include(input_tokens: 100, output_tokens: 10)
      expect(wire[:request_content_hash]).to eq(event[:request_content_hash])
      expect(wire[:response_content_hash]).to eq(event[:response_content_hash])
      expect(wire[:capture]).to include(mode: 'projected', omitted_field_count: 2, omitted_message_count: 1)
    end

    it 'removes oldest audit messages only after binary compaction cannot satisfy the budget' do
      Legion::Settings[:transport][:max_payload_bytes] = 4_096
      request = Legion::LLM::Inference::Request.build(messages: [
                                                        { role: :user, content: 'old' * 2_000 }, { role: :user, content: 'recent' }
                                                      ])
      response = Legion::LLM::Inference::Response.build(
        request_id: 'r', conversation_id: 'conversation', message: { role: :assistant, content: 'answer' }
      )
      event = Legion::LLM::Inference::AuditPublisher.build_event(request: request, response: response)
      wire = publish_event(event)

      expect(wire[:messages].map { |message| message[:content] }).to eq(['recent'])
      expect(wire[:capture]).to include(original_message_count: 2, captured_message_count: 1, omitted_message_count: 1)
      expect(wire[:request_content_hash]).to eq(event[:request_content_hash])
      expect(request.messages.map(&:content)).to eq(['old' * 2_000, 'recent'])
    end

    it 'counts attribution and runtime caller bytes when enforcing a lower configured limit' do
      Legion::Settings[:transport][:max_payload_bytes] = 4_096
      event = prompt_audit_event(content: 'M' * 3_000)
      event[:caller] = { requested_by: { identity: 'user:matt', type: :user }, context: 'C' * 1_000 }
      message = described_class.new(**Legion::LLM::Audit.attributed_event(event))
      allow(message).to receive(:resolve_caller_class).and_return('RuntimeCaller' * 50)
      allow(message).to receive(:exchange).and_return(audit_exchange)

      result = message.publish(return_result: true)
      wire = Legion::JSON.load(published_bodies.last)

      expect(result[:accepted]).to be(true)
      expect(published_bodies.last.bytesize).to be <= 4_096
      expect(wire[:caller][:class]).to eq('RuntimeCaller' * 50)
      expect(wire[:capture]).to include(omitted_message_count: 1, payload_limit_bytes: 4_096)
      expect(wire[:identity]).to include(identity: 'matt@example.com')
    end

    it 'budgets encryption expansion as well as the transport cleartext size gate' do
      Legion::Settings[:llm][:compliance][:encrypt_audit] = true
      stub_const('Legion::Crypt', Module.new)
      allow(Legion::Crypt).to receive(:encrypt) do |payload|
        { enciphered_message: Base64.strict_encode64(payload), iv: 'test-iv' }
      end
      event = prompt_audit_event(content: 'M' * 2_000)
      limit = Legion::JSON.dump(event).bytesize + 128
      Legion::Settings[:transport][:max_payload_bytes] = limit
      message = described_class.new(**event)
      allow(message).to receive(:exchange).and_return(audit_exchange)

      result = message.publish(return_result: true)
      wire = Legion::JSON.load(Base64.strict_decode64(published_bodies.last))

      expect(result[:accepted]).to be(true)
      expect(published_bodies.last.bytesize).to be <= limit
      expect(Legion::JSON.dump(message.message).bytesize).to be <= limit
      expect(wire[:capture][:omitted_message_count]).to eq(1)
    end

    it 'drops explicitly when the configured limit cannot hold the minimum audit envelope' do
      Legion::Settings[:transport][:max_payload_bytes] = 128
      Legion::Settings[:transport][:connected] = true
      event = prompt_audit_event(content: 'hello')

      expect { described_class.new(**event).publish(return_result: true) }.to raise_error(Legion::Transport::PayloadTooLarge)
      expect(Legion::LLM::Audit.emit_prompt(event)).to eq(:dropped)
      expect(published_bodies).to be_empty
    end
  end
end
