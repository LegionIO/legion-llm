# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::AuditPublisher do
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

  describe '.build_event' do
    before do
      stub_process_identity
    end

    it 'builds event with required fields from request and response' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'req_abc', conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' },
        caller: { requested_by: { identity: 'user:matt', type: :user, credential: :api } }
      )
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }]
      )

      event = described_class.build_event(request: request, response: response)
      expect(event).to be_a(Hash)
      expect(event[:request_id]).to eq('req_abc')
      expect(event[:conversation_id]).to eq('conv_xyz')
      expect(event[:caller]).to eq(response.caller)
      expect(event[:identity]).to eq({ requested_by: { identity: 'user:matt', type: :user, credential: :api } })
      expect(event[:tokens]).to be_a(Hash)
      expect(event[:routing]).to eq(response.routing)
      expect(event[:timestamp]).to be_a(Time)
    end

    it 'serializes ::Data.define tokens to a hash' do
      usage = ::Data.define(:input_tokens, :output_tokens).new(input_tokens: 100, output_tokens: 20)
      response = Legion::LLM::Inference::Response.build(
        request_id: 'r', conversation_id: 'c',
        message: { role: :assistant, content: 'hi' },
        tokens: usage
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)
      expect(event[:tokens]).to be_a(Hash)
      expect(event[:tokens][:input_tokens]).to eq(100)
      expect(event[:tokens][:output_tokens]).to eq(20)
    end

    it 'includes system_prompt and injected_tools from provider_payload audit' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'r', conversation_id: 'c',
        message: { role: :assistant, content: 'hi' },
        audit: { provider_payload: { system_prompt: 'You are Legion.', injected_tools: %w[tool_a tool_b], tool_count: 2 } }
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)
      expect(event[:system_prompt]).to eq('You are Legion.')
      expect(event[:injected_tools]).to eq(%w[tool_a tool_b])
      expect(event[:audit]).not_to have_key(:provider_payload)
    end

    it 'reads string-keyed provider payloads and routing metadata' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'r', conversation_id: 'c',
        message: { 'role' => 'assistant', 'content' => 'answer' },
        routing: { 'provider' => 'bedrock', 'model' => 'claude-sonnet-4-6', 'tier' => 'cloud' },
        audit: { 'provider_payload' => { 'system_prompt' => 'sys', 'injected_tools' => ['tool_a'] }, 'kept' => true }
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)

      expect(event[:response_content]).to eq('answer')
      expect(event[:system_prompt]).to eq('sys')
      expect(event[:injected_tools]).to eq(['tool_a'])
      expect(event[:tier]).to eq('cloud')
      expect(event[:audit]).to eq('kept' => true)
    end

    it 'includes compacted enrichments in event' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'req_abc', conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' },
        enrichments: { 'gaia:advisory' => { content: 'valence summary', data: { valence: [0.3, 0.5, 0.7] } } }
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)
      expect(event[:enrichments]).to have_key('gaia:advisory')
      expect(event[:enrichments]['gaia:advisory'][:data][:valence]).to eq(0.7)
    end

    it 'compacts string-keyed enrichments' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'req_abc', conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' },
        enrichments: { 'gaia:advisory' => { 'content' => 'summary', 'data' => { 'valence' => [0.1, 0.8] } } }
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)
      expect(event[:enrichments]['gaia:advisory'][:content]).to eq('summary')
      expect(event[:enrichments]['gaia:advisory'][:data]['valence']).to eq(0.8)
    end

    it 'filters timeline to provider and escalation events only' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'req_abc', conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' },
        timeline: [
          { seq: 1, key: 'tracing:init' },
          { seq: 2, key: 'provider:request_sent', detail: 'streaming from bedrock' },
          { seq: 3, key: 'provider:response_received', detail: 'response received' },
          { seq: 4, key: 'context:stored' }
        ]
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)
      expect(event[:timeline].size).to eq(2)
      expect(event[:timeline].map { |e| e[:key] }).to eq(%w[provider:request_sent provider:response_received])
    end

    it 'includes response_content and messages' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'r', conversation_id: 'c',
        message: { role: :assistant, content: 'answer' }
      )
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'question' }]
      )

      event = described_class.build_event(request: request, response: response)
      expect(event[:response_content]).to eq('answer')
      wire_messages = Legion::JSON.load(Legion::JSON.dump(event))[:messages]
      expect(wire_messages).to contain_exactly(include(role: 'user', content: 'question'))
    end

    it 'includes response_thinking separately from response_content' do
      thinking = { content: 'internal chain', enabled: true, config: { budget_tokens: 128 } }
      response = Legion::LLM::Inference::Response.build(
        request_id: 'r', conversation_id: 'c',
        message:  { role: :assistant, content: 'answer' },
        thinking: thinking
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)

      expect(event[:response_content]).to eq('answer')
      expect(event[:response_thinking]).to eq(thinking)
    end

    it 'keeps extension caller context and uses caller hash as identity' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'r', conversation_id: 'c',
        message: { role: :assistant, content: 'answer' },
        caller: { extension: 'lex-test' }
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)

      expect(event[:caller]).to eq(extension: 'lex-test')
      expect(event[:identity]).to eq(extension: 'lex-test')
    end

    it 'uses namespaced caller hash directly as identity' do
      caller_hash = {
        requested_by: {
          id:         'system:system',
          identity:   'system',
          type:       'service',
          credential: 'system'
        }
      }
      response = Legion::LLM::Inference::Response.build(
        request_id: 'r', conversation_id: 'c',
        message: { role: :assistant, content: 'answer' },
        caller: caller_hash
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)

      expect(event[:identity]).to eq(caller_hash)
    end

    it 'does not let string caller identity override publisher identity' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'r', conversation_id: 'c',
        message: { role: :assistant, content: 'answer' },
        caller: 'extension:lex-test'
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)

      expect(event[:identity]).to eq(identity: 'matt@example.com', type: :human, credential: :system)
    end

    context 'with canonical prompt content' do
      let(:response) do
        Legion::LLM::Inference::Response.build(
          request_id: 'r', conversation_id: 'c',
          message: { role: :assistant, content: 'answer' }
        )
      end
      let(:canonical) { Legion::Extensions::Llm::Canonical }

      def event_for(messages)
        request = Legion::LLM::Inference::Request.build(messages: messages)
        described_class.build_event(request: request, response: response)
      end

      it 'bounds only the audit projection of more than twenty canonical messages' do
        messages = Array.new(25) { |index| canonical::Message.build(role: :user, content: "turn #{index}") }
        request = Legion::LLM::Inference::Request.build(messages: messages)
        original = Legion::JSON.dump(request.messages)

        event = described_class.build_event(request: request, response: response)

        expect(event[:messages].map { |message| message[:content] }).to eq((5...25).map { |index| "turn #{index}" })
        expect(event[:capture]).to include(mode: :projected, original_message_count: 25,
                                           captured_message_count: 20, omitted_message_count: 5)
        expect(Legion::JSON.dump(request.messages)).to eq(original)
        changed_history = messages.dup
        changed_history[0] = canonical::Message.build(role: :user, content: 'different old turn')
        expect(event_for(changed_history)[:request_content_hash]).not_to eq(event[:request_content_hash])
      end

      it 'distinguishes images with identical surrounding text and hashes image-only requests' do
        image_a = canonical::ContentBlock.image(data: 'QUJD', media_type: 'image/png')
        image_b = canonical::ContentBlock.image(data: 'REVG', media_type: 'image/png')
        text = canonical::ContentBlock.text('describe')
        first = event_for([{ role: :user, content: [text, image_a] }])
        second = event_for([{ role: :user, content: [text, image_b] }])
        image_only = event_for([{ role: :user, content: image_a }])

        expect(first[:request_content_hash]).not_to eq(second[:request_content_hash])
        expect(image_only[:request_content_hash]).to match(/\A[0-9a-f]{64}\z/)
        expect(image_only[:request_content_hash]).not_to eq(event_for([{ role: :user, content: image_b }])[:request_content_hash])
      end

      it 'ignores generated message identity while retaining roles and tool state in the digest' do
        message = canonical::Message.build(role: :assistant, id: 'one', timestamp: Time.at(1),
                                           tool_calls: [{ id: 'call-1', name: 'lookup', arguments: { b: 2, a: 1 } }])
        rebuilt = canonical::Message.build(role: :assistant, id: 'two', timestamp: Time.at(2),
                                           tool_calls: [{ id: 'call-1', name: 'lookup', arguments: { a: 1, b: 2 } }])
        changed = canonical::Message.build(role:       :assistant,
                                           tool_calls: [{ id: 'call-1', name: 'lookup', arguments: { a: 9, b: 2 } }])
        digest = event_for([message])[:request_content_hash]
        expect(event_for([rebuilt])[:request_content_hash]).to eq(digest)
        expect(event_for([changed])[:request_content_hash]).not_to eq(digest)
        expect(event_for([{ role: :user, content: 'same' }])[:request_content_hash])
          .not_to eq(event_for([{ role: :assistant, content: 'same' }])[:request_content_hash])
      end

      it 'fingerprints an oversized image without labelling the fingerprint as reusable base64' do
        data = 'A' * 1_500_000
        request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: [
                                                          canonical::ContentBlock.text('what is this?'),
                                                          canonical::ContentBlock.image(data: data, media_type: 'image/png')
                                                        ] }])
        original = Legion::JSON.dump(request.messages)
        event = described_class.build_event(request: request, response: response)
        wire = Legion::JSON.load(Legion::JSON.dump(event))
        image = wire[:messages].first[:content].last

        expect(image[:binary_fingerprint]).to eq(bytes: data.bytesize, sha256: Digest::SHA256.hexdigest(data),
                                                 media_type: 'image/png', source_type: 'base64')
        expect(image).not_to have_key(:data)
        expect(image).not_to have_key(:source_type)
        expect(wire[:messages].first[:content].first[:text]).to eq('what is this?')
        expect(event[:capture]).to include(mode: :projected, redacted_binary_count: 1, redacted_binary_bytes: data.bytesize)
        expect(Legion::JSON.dump(request.messages)).to eq(original)
      end

      it 'preserves subthreshold media data on the audit wire until a total budget requires compaction' do
        event = event_for([{ role: :user, content: [canonical::ContentBlock.image(data: 'QUJD', media_type: 'image/png')] }])
        image = Legion::JSON.load(Legion::JSON.dump(event))[:messages].first[:content].first

        expect(image).to include(type: 'image', data: 'QUJD', source_type: 'base64')
        expect(event[:capture]).to include(mode: :full, redacted_binary_count: 0)
      end

      it 'fingerprints nested canonical tool media and single audio/video blocks without changing inference content' do
        data = 'A' * 150_000
        image = canonical::ContentBlock.image(data: data, media_type: 'image/png')
        result = canonical::ContentBlock.tool_result(tool_use_id: 'call-1', content: [image])
        messages = [
          canonical::Message.build(role: :tool, content: result),
          canonical::Message.build(role: :user, content: canonical::ContentBlock.build(type: :audio, data: data, media_type: 'audio/wav')),
          canonical::Message.build(role: :user, content: canonical::ContentBlock.build(type: :video, data: data, media_type: 'video/mp4'))
        ]
        original = Legion::JSON.dump(messages)
        event = event_for(messages)
        wire = Legion::JSON.load(Legion::JSON.dump(event))

        expect(wire[:messages].first[:content][:text].first[:binary_fingerprint][:bytes]).to eq(data.bytesize)
        expect(wire[:messages].drop(1).map { |message| message[:content][:binary_fingerprint][:media_type] })
          .to eq(%w[audio/wav video/mp4])
        expect(event[:capture][:redacted_binary_count]).to eq(3)
        expect(Legion::JSON.dump(messages)).to eq(original)
      end
    end
  end

  describe '.publish' do
    it 'returns the built event with a disabled transport outcome for local observation' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'req_abc', conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' }
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      result = described_class.publish(request: request, response: response)
      expect(result[:status]).to eq(:disabled)
      expect(result[:event][:request_id]).to eq('req_abc')
    end

    it 'reports a dropped event when building fails' do
      response = double('response')
      allow(response).to receive(:request_id).and_raise(StandardError, 'boom')

      result = described_class.publish(request: double, response: response)
      expect(result).to eq(event: nil, status: :dropped)
    end

    it 'preserves a built event when publishing drops it' do
      request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'hello' }])
      response = Legion::LLM::Inference::Response.build(request_id: 'r', conversation_id: 'conversation', message: { role: :assistant, content: 'ok' })
      allow(Legion::LLM::Audit).to receive(:emit_prompt).and_return(:dropped)

      result = described_class.publish(request: request, response: response)

      expect(result[:status]).to eq(:dropped)
      expect(result[:event][:messages].first[:content]).to eq('hello')
    end
  end
end
