# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Fleet::Dispatcher do
  let(:future) { instance_double(Concurrent::Promises::ResolvableFuture) }

  describe '.fleet_available?' do
    it 'returns false when transport is not connected' do
      expect(described_class.fleet_available?).to eq(false)
    end
  end

  describe '.fleet_enabled?' do
    it 'returns false by default' do
      expect(described_class.fleet_enabled?).to eq(false)
    end

    it 'returns false when fleet dispatch is disabled' do
      Legion::Settings[:llm][:fleet] = { dispatch: { enabled: false } }
      expect(described_class.fleet_enabled?).to eq(false)
    end

    it 'returns false when fleet dispatch settings disable fleet' do
      Legion::Settings[:llm][:fleet] = { dispatch: { enabled: false } }
      expect(described_class.fleet_enabled?).to eq(false)
    end

    it 'ignores the removed routing.use_fleet setting' do
      Legion::Settings[:llm][:fleet] = { dispatch: { enabled: true } }
      Legion::Settings[:llm][:routing] = { use_fleet: false }
      expect(described_class.fleet_enabled?).to eq(true)
    end
  end

  describe '.dispatch' do
    it 'returns fleet_unavailable when fleet is not available' do
      result = described_class.dispatch(
        operation: :chat,
        request:   { provider: 'ollama', provider_instance: 'default', model: 'test', messages: [] }
      )
      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('fleet_unavailable')
    end

    it 'requires an operation' do
      expect do
        described_class.dispatch(request: { provider: 'ollama', model: 'test' })
      end.to raise_error(ArgumentError, /operation is required/)
    end

    it 'publishes protocol-v3 exact-execution fleet request envelopes without legacy fields' do
      order = []
      published_options = nil
      fleet_message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetRequest)

      allow(described_class).to receive(:fleet_available?).and_return(true)
      allow(future).to receive(:value!).and_return({ success: true })
      allow(Legion::LLM::Fleet::TokenIssuer).to receive(:issue).and_return('signed-token')
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:agent_queue_name).and_return('llm.fleet.reply.test')
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:register) do |correlation_id, expected:|
        order << :register
        expect(correlation_id).to match(/\Areq_/)
        expect(expected).to include(
          protocol_version: 3,
          operation:        :chat,
          correlation_id:   correlation_id
        )
        future
      end
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:deregister)
      expect(fleet_message).to receive(:publish).with(
        hash_including(
          mandatory:                  true,
          publisher_confirm:          true,
          publish_confirm_timeout_ms: 500,
          spool:                      false,
          return_result:              true
        )
      ) do
        order << :publish
        { accepted: true, status: :accepted }
      end
      expect(Legion::Extensions::Llm::Transport::Messages::FleetRequest).to receive(:new) do |options|
        published_options = options
        expect(options).to include(
          operation:          :chat,
          provider:           'ollama',
          provider_instance:  'default',
          model:              'qwen3.6:27b',
          reply_to:           'llm.fleet.reply.test',
          protocol_version:   3,
          execution_contract: 'exact_offering_v1',
          offering_id:        'off:v1:test',
          request_id:         a_string_matching(/\Areq_/),
          correlation_id:     a_string_matching(/\Areq_/),
          idempotency_key:    a_string_matching(/\Aidem_/),
          signed_token:       'signed-token'
        )
        expect(options).not_to include(:request_type)
        expect(options).not_to include(:fleet_correlation_id)
        fleet_message
      end

      described_class.dispatch(
        operation:       :chat,
        request:         {
          provider:           'ollama',
          provider_instance:  'default',
          model:              'qwen3.6:27b',
          messages:           [{ role: 'user', content: 'hello' }],
          execution_contract: 'exact_offering_v1',
          offering_id:        'off:v1:test'
        },
        message_context: { request_id: 'caller-req' },
        timeout:         1
      )

      expect(order).to eq(%i[register publish])
      expect(published_options[:params]).to eq(messages: [{ role: 'user', content: 'hello' }])
      expect(published_options[:message_context]).to eq(request_id: 'caller-req')
    end

    it 'publishes unsigned requests when fleet dispatch auth is disabled' do
      published_options = nil
      fleet_message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetRequest)

      # timeout_seconds mirrors the registered settings default (the real
      # settings tree deep-merges llm.fleet.dispatch.timeout_seconds).
      Legion::Settings[:llm][:fleet] = { dispatch: { require_auth: false, timeout_seconds: 30 } }
      allow(described_class).to receive(:fleet_available?).and_return(true)
      allow(future).to receive(:value!).and_return({ success: true })
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:agent_queue_name).and_return('llm.fleet.reply.test')
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:register).and_return(future)
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:deregister)
      allow(fleet_message).to receive(:publish).and_return({ accepted: true, status: :accepted })
      allow(Legion::Extensions::Llm::Transport::Messages::FleetRequest).to receive(:new) do |options|
        published_options = options
        fleet_message
      end

      expect(Legion::LLM::Fleet::TokenIssuer).not_to receive(:issue)

      described_class.dispatch(operation: :chat, request: { provider: 'ollama', provider_instance: 'default', model: 'test', execution_contract: 'exact_offering_v1', offering_id: 'off:v1:test' })

      expect(published_options[:signed_token]).to eq('unsigned')
    end

    it 'inherits dispatch auth from shared fleet auth policy when dispatch override is unset' do
      published_options = nil
      fleet_message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetRequest)

      # timeout_seconds mirrors the registered settings default (the real
      # settings tree deep-merges llm.fleet.dispatch.timeout_seconds).
      Legion::Settings[:llm][:fleet] = { dispatch: { timeout_seconds: 30 }, auth: { require_signed_token: false } }
      allow(described_class).to receive(:fleet_available?).and_return(true)
      allow(future).to receive(:value!).and_return({ success: true })
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:agent_queue_name).and_return('llm.fleet.reply.test')
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:register).and_return(future)
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:deregister)
      allow(fleet_message).to receive(:publish).and_return({ accepted: true, status: :accepted })
      allow(Legion::Extensions::Llm::Transport::Messages::FleetRequest).to receive(:new) do |options|
        published_options = options
        fleet_message
      end

      expect(Legion::LLM::Fleet::TokenIssuer).not_to receive(:issue)

      described_class.dispatch(operation: :chat, request: { provider: 'ollama', provider_instance: 'default', model: 'test', execution_contract: 'exact_offering_v1', offering_id: 'off:v1:test' })

      expect(published_options[:signed_token]).to eq('unsigned')
    end

    it 'rejects legacy fleet fields instead of forwarding them in params' do
      allow(described_class).to receive(:fleet_available?).and_return(true)

      expect do
        described_class.dispatch(
          operation: :chat,
          request:   { provider: 'ollama', model: 'test', request_type: 'chat' }
        )
      end.to raise_error(ArgumentError, /request_type/)
    end

    it 'uses the effective wait timeout as the fleet message TTL' do
      published = nil
      fleet_message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetRequest)

      allow(described_class).to receive(:fleet_available?).and_return(true)
      allow(future).to receive(:value!).and_return({ success: true })
      allow(Legion::LLM::Fleet::TokenIssuer).to receive(:issue).and_return('signed-token')
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:register).and_return(future)
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:deregister)
      allow(fleet_message).to receive(:publish).and_return({ accepted: true, status: :accepted })
      allow(Legion::Extensions::Llm::Transport::Messages::FleetRequest).to receive(:new) do |options|
        published = options
        fleet_message
      end

      described_class.dispatch(operation: :chat,
                               request: { provider: 'ollama', provider_instance: 'default', model: 'test', execution_contract: 'exact_offering_v1', offering_id: 'off:v1:test' }, timeout: 7)

      expect(published[:ttl]).to eq(7)
      expect(published[:timeout_seconds]).to eq(7)
    end

    it 'builds context-aware lanes from string-keyed request limits' do
      published = nil
      fleet_message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetRequest)
      request = {
        'provider'           => 'ollama',
        'provider_instance'  => 'default',
        'model'              => 'qwen3.6:27b',
        'execution_contract' => 'exact_offering_v1',
        'offering_id'        => 'off:v1:test',
        'limits'             => { 'context_window' => 65_536 },
        'ttl'                => 9
      }
      allow(described_class).to receive(:fleet_available?).and_return(true)
      allow(future).to receive(:value!).and_return({ success: true })
      allow(Legion::LLM::Fleet::TokenIssuer).to receive(:issue).and_return('signed-token')
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:register).and_return(future)
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:deregister)
      allow(fleet_message).to receive(:publish).and_return({ accepted: true, status: :accepted })
      allow(Legion::Extensions::Llm::Transport::Messages::FleetRequest).to receive(:new) do |options|
        published = options
        fleet_message
      end

      described_class.dispatch(operation: :chat, request: request)

      expect(published[:routing_key]).to eq('llm.fleet.inference.qwen3-6-27b.ctx65536')
      expect(published[:ttl]).to eq(9)
    end

    it 'returns a structured error when fleet publish is unroutable' do
      allow(described_class).to receive(:fleet_available?).and_return(true)
      allow(Legion::LLM::Fleet::TokenIssuer).to receive(:issue).and_return('signed-token')
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:register)
        .and_return(instance_double(Concurrent::Promises::ResolvableFuture))
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:deregister)
      allow(described_class).to receive(:publish_request)
        .and_return({ accepted: false, status: :unroutable })

      result = described_class.dispatch(
        operation:       :chat,
        request:         { provider: 'ollama', provider_instance: 'default', model: 'test', execution_contract: 'exact_offering_v1', offering_id: 'off:v1:test' },
        message_context: { request_id: 'req-1' }
      )

      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('no_fleet_queue')
      expect(result[:publish_status]).to eq(:unroutable)
      expect(result[:message_context]).to eq({ request_id: 'req-1' })
    end
  end

  describe '.resolve_timeout' do
    it 'returns default timeout when no override' do
      expect(described_class.resolve_timeout).to eq(30)
    end

    it 'returns override when provided' do
      expect(described_class.resolve_timeout(override: 60)).to eq(60)
    end

    it 'reads from fleet dispatch settings' do
      Legion::Settings[:llm][:fleet] = { dispatch: { timeout_seconds: 45 } }
      expect(described_class.resolve_timeout).to eq(45)
    end

    it 'reads per-type timeouts' do
      expect(described_class.resolve_timeout(operation: :embed)).to eq(10)
    end

    it 'reads per-type timeouts from settings' do
      Legion::Settings[:llm][:fleet] = { dispatch: { timeouts: { chat: 60 } } }
      expect(described_class.resolve_timeout(operation: :chat)).to eq(60)
    end

    it 'reads per-type timeouts and default timeout from settings' do
      Legion::Settings[:llm][:fleet] = {
        dispatch: {
          timeouts:        { embed: 12 },
          timeout_seconds: 45
        }
      }

      expect(described_class.resolve_timeout(operation: :embed)).to eq(12)
      expect(described_class.resolve_timeout(operation: :chat)).to eq(45)
    end
  end

  describe '.build_routing_key' do
    it 'builds shared fleet lane keys by default' do
      key = described_class.build_routing_key(provider: 'ollama', operation: 'chat', model: 'qwen3.5:27b')
      expect(key).to eq('llm.fleet.inference.qwen3-5-27b')
    end

    it 'can build legacy provider/model keys for compatibility' do
      key = described_class.build_routing_key(
        provider:      'ollama',
        operation:     'chat',
        model:         'qwen3.5:27b',
        routing_style: :legacy_provider_model
      )
      expect(key).to eq('llm.request.ollama.chat.qwen3.5.27b')
    end

    it 'can build target shared lane keys with context windows' do
      key = described_class.build_routing_key(
        provider:       'ollama',
        operation:      'chat',
        model:          'qwen3.6:27b',
        context_window: 32_768,
        routing_style:  :shared_lane
      )

      expect(key).to eq('llm.fleet.inference.qwen3-6-27b.ctx32768')
    end

    it 'can build exact offering lane keys for provider instances' do
      key = described_class.build_routing_key(
        provider:          'vllm',
        provider_instance: 'macbook-m4',
        operation:         'chat',
        model:             'qwen3.6:27b',
        routing_style:     :offering_lane
      )

      expect(key).to eq('llm.fleet.offering.macbook-m4.qwen3-6-27b.inference')
    end

    it 'reads routing style from fleet dispatch settings' do
      Legion::Settings[:llm][:fleet] = {
        dispatch: { routing_style: 'legacy_provider_model' }
      }

      key = described_class.build_routing_key(provider: 'ollama', operation: 'chat', model: 'qwen3.5:27b')

      expect(key).to eq('llm.request.ollama.chat.qwen3.5.27b')
    end
  end

  describe '.sanitize_model' do
    it 'replaces colons with dots' do
      expect(described_class.sanitize_model('qwen3.5:27b')).to eq('qwen3.5.27b')
    end

    it 'preserves other characters' do
      expect(described_class.sanitize_model('llama3.2')).to eq('llama3.2')
    end
  end

  describe '.error_result' do
    it 'includes message_context' do
      result = described_class.error_result('test', message_context: { id: 1 })
      expect(result[:message_context]).to eq({ id: 1 })
    end
  end

  describe '.timeout_result' do
    it 'includes message_context' do
      result = described_class.timeout_result('corr_1', 30, message_context: { id: 1 })
      expect(result[:message_context]).to eq({ id: 1 })
    end
  end
end

RSpec.describe Legion::LLM::Fleet::ReplyDispatcher do
  before do
    described_class.reset!
    allow(described_class).to receive(:ensure_consumer)
  end

  it 'accepts versioned fleet responses' do
    future = described_class.register('corr-123', expected: {
                                        protocol_version: 3,
                                        operation:        :chat,
                                        correlation_id:   'corr-123'
                                      })

    described_class.handle_delivery(
      { protocol_version: 3, operation: :chat, correlation_id: 'corr-123', success: true, content: 'hello' },
      { correlation_id: 'corr-123', type: 'llm.fleet.response' }
    )

    expect(future.value!).to eq(
      correlation_id:   'corr-123',
      protocol_version: 3,
      operation:        :chat,
      success:          true,
      content:          'hello'
    )
  end

  it 'accepts versioned fleet errors and normalizes them' do
    future = described_class.register('corr-456', expected: {
                                        protocol_version: 3,
                                        operation:        :chat,
                                        correlation_id:   'corr-456'
                                      })

    described_class.handle_delivery(
      { protocol_version: 3, operation: :chat, code: 'model_not_loaded', message: 'not available', correlation_id: 'corr-456',
        message_context: { conv: 'c1' } },
      { correlation_id: 'corr-456', type: 'llm.fleet.error' }
    )

    result = future.value!
    expect(result[:success]).to eq(false)
    expect(result[:error]).to eq('model_not_loaded')
    expect(result[:correlation_id]).to eq('corr-456')
    expect(result[:message_context]).to eq({ conv: 'c1' })
  end

  it 'ignores unversioned responses' do
    described_class.register('corr-legacy', expected: {
                               protocol_version: 3,
                               operation:        :chat,
                               correlation_id:   'corr-legacy'
                             })

    described_class.handle_delivery(
      { operation: :chat, correlation_id: 'corr-legacy', success: true },
      { correlation_id: 'corr-legacy', type: 'llm.fleet.response' }
    )

    expect(described_class.pending_count).to eq(1)
  end

  it 'ignores malformed protocol versions that do not match v3' do
    described_class.register('corr-malformed', expected: {
                               protocol_version: 3,
                               operation:        :chat,
                               correlation_id:   'corr-malformed'
                             })

    described_class.handle_delivery(
      { protocol_version: '2junk', operation: :chat, correlation_id: 'corr-malformed', success: true },
      { correlation_id: 'corr-malformed', type: 'llm.fleet.response' }
    )

    expect(described_class.pending_count).to eq(1)
  end

  it 'ignores no-type fallback responses' do
    described_class.register('corr-notype', expected: {
                               protocol_version: 3,
                               operation:        :chat,
                               correlation_id:   'corr-notype'
                             })

    described_class.handle_delivery(
      { protocol_version: 3, operation: :chat, correlation_id: 'corr-notype', success: true }
    )

    expect(described_class.pending_count).to eq(1)
  end

  it 'ignores responses with the wrong correlation id' do
    described_class.register('corr-expected', expected: {
                               protocol_version: 3,
                               operation:        :chat,
                               correlation_id:   'corr-expected'
                             })

    described_class.handle_delivery(
      { protocol_version: 3, operation: :chat, correlation_id: 'corr-other', success: true },
      { correlation_id: 'corr-other', type: 'llm.fleet.response' }
    )

    expect(described_class.pending_count).to eq(1)
  end

  it 'ignores responses whose AMQP property matches but payload correlation_id is wrong' do
    described_class.register('corr-expected', expected: {
                               protocol_version: 3,
                               operation:        :chat,
                               correlation_id:   'corr-expected'
                             })

    described_class.handle_delivery(
      { protocol_version: 3, operation: :chat, correlation_id: 'corr-other', success: true },
      { correlation_id: 'corr-expected', type: 'llm.fleet.response' }
    )

    expect(described_class.pending_count).to eq(1)
  end

  it 'ignores late responses after deregister' do
    described_class.register('corr-late', expected: {
                               protocol_version: 3,
                               operation:        :chat,
                               correlation_id:   'corr-late'
                             })
    described_class.deregister('corr-late')

    described_class.handle_delivery(
      { protocol_version: 3, operation: :chat, correlation_id: 'corr-late', success: true },
      { correlation_id: 'corr-late', type: 'llm.fleet.response' }
    )

    expect(described_class.pending_count).to eq(0)
  end

  it 'keeps pending requests until a matching response arrives or the caller times out' do
    described_class.register('corr-waiting')

    expect(described_class.pending_count).to eq(1)
  end
end
