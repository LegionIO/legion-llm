# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/transport/exchanges/fleet'
require 'legion/llm/transport/messages/fleet_request'
require 'legion/llm/transport/messages/fleet_response'
require 'legion/llm/transport/messages/fleet_error'

RSpec.describe Legion::LLM::Transport::Messages::FleetRequest do
  let(:base_opts) do
    {
      routing_key:          'llm.request.ollama.chat.llama3.2',
      reply_to:             'llm.fleet.reply.abc123',
      fleet_correlation_id: 'req_abc',
      provider:             'ollama',
      model:                'llama3.2',
      request_type:         'chat',
      message_context:      { conversation_id: 'conv_1', message_id: 'msg_1', request_id: 'req_1' },
      messages:             [{ role: 'user', content: 'hello' }]
    }
  end

  def build(**)
    described_class.new(**base_opts, **)
  end

  describe '#type' do
    it 'returns llm.fleet.request' do
      expect(build.type).to eq('llm.fleet.request')
    end
  end

  describe '#routing_key' do
    it 'reads from options' do
      expect(build.routing_key).to eq('llm.request.ollama.chat.llama3.2')
    end
  end

  describe '#reply_to' do
    it 'reads from options' do
      expect(build.reply_to).to eq('llm.fleet.reply.abc123')
    end
  end

  describe '#priority' do
    it 'maps :critical to 9' do
      expect(build(priority: :critical).priority).to eq(9)
    end

    it 'maps :high to 7' do
      expect(build(priority: :high).priority).to eq(7)
    end

    it 'maps :normal to 5' do
      expect(build(priority: :normal).priority).to eq(5)
    end

    it 'maps :low to 2' do
      expect(build(priority: :low).priority).to eq(2)
    end

    it 'passes integer through' do
      expect(build(priority: 3).priority).to eq(3)
    end

    it 'defaults to 5 for unknown symbol' do
      expect(build(priority: :unknown).priority).to eq(5)
    end
  end

  describe '#expiration' do
    it 'converts TTL seconds to ms string' do
      expect(build(ttl: 30).expiration).to eq('30000')
    end

    it 'accepts string TTL values' do
      expect(build(ttl: '2.5').expiration).to eq('2500')
    end

    it 'ignores non-positive or invalid TTL values' do
      expect(build(ttl: 0).expiration).to be_nil
      expect(build(ttl: 'nope').expiration).to be_nil
    end

    it 'returns nil when no TTL' do
      expect(build.expiration).to be_nil
    end
  end

  describe '#publish_confirm_timeout_ms' do
    it 'reads publish confirm timeouts from string-keyed settings' do
      Legion::Settings[:llm]['routing'] = {
        'tiers' => { 'fleet' => { 'publish_confirm_timeout_ms' => 1250 } }
      }

      expect(build.send(:publish_confirm_timeout_ms)).to eq(1250)
    end
  end

  describe '#message_id' do
    it 'has req prefix' do
      expect(build.message_id).to match(/\Areq_/)
    end
  end

  describe '#message (body)' do
    it 'excludes envelope keys' do
      body = build.message
      expect(body).not_to have_key(:fleet_correlation_id)
      expect(body).not_to have_key(:provider)
      expect(body).not_to have_key(:model)
      expect(body).not_to have_key(:ttl)
    end

    it 'includes message_context in body' do
      body = build.message
      expect(body[:message_context]).to eq({ conversation_id: 'conv_1', message_id: 'msg_1', request_id: 'req_1' })
    end

    it 'includes request_type in body' do
      body = build.message
      expect(body[:request_type]).to eq('chat')
    end

    it 'includes reply routing fields in body for fleet workers' do
      body = build.message
      expect(body[:reply_to]).to eq('llm.fleet.reply.abc123')
      expect(body[:correlation_id]).to eq('req_abc')
    end
  end

  describe '#headers' do
    it 'emits message context headers from string-keyed context hashes' do
      headers = build(message_context: {
                        'conversation_id' => 'conv_json',
                        'message_id'      => 'msg_json',
                        'request_id'      => 'req_json'
                      }).headers

      expect(headers['x-legion-llm-conversation-id']).to eq('conv_json')
      expect(headers['x-legion-llm-message-id']).to eq('msg_json')
      expect(headers['x-legion-llm-request-id']).to eq('req_json')
    end
  end
end

RSpec.describe 'fleet reply messages' do
  let(:exchange_class) do
    Class.new do
      attr_reader :channel, :published_options

      def initialize(channel)
        @channel = channel
      end

      def name = ''

      def publish(_payload, **options)
        @published_options = options
      end
    end
  end

  let(:channel_class) do
    exchange_klass = exchange_class
    Class.new do
      attr_reader :exchange, :confirm_timeout

      define_method(:initialize) do
        @exchange = exchange_klass.new(self)
      end

      def default_exchange = @exchange
      def confirm_select = @confirm_selected = true

      def wait_for_confirms(timeout = nil)
        @confirm_timeout = timeout
        true
      end

      def on_return(&); end
    end
  end

  let(:channel) { channel_class.new }

  before do
    allow(Legion::Transport::Connection).to receive(:channel).and_return(channel) if
      defined?(Legion::Transport::Connection)
  end

  it 'publishes fleet responses as mandatory confirmed no-spool live replies' do
    message = Legion::LLM::Transport::Messages::FleetResponse.new(
      channel:              channel,
      reply_to:             'llm.fleet.reply.abc123',
      fleet_correlation_id: 'corr-1',
      response:             'ok'
    )

    result = message.publish

    expect(result[:status]).to eq(:accepted)
    expect(result[:accepted]).to eq(true)
    expect(channel.exchange.published_options[:mandatory]).to eq(true)
    expect(channel.confirm_timeout).to eq(0.5)
  end

  it 'publishes fleet errors as mandatory confirmed no-spool live replies' do
    message = Legion::LLM::Transport::Messages::FleetError.new(
      channel:              channel,
      reply_to:             'llm.fleet.reply.abc123',
      fleet_correlation_id: 'corr-1',
      error:                { code: 'model_not_loaded' }
    )

    result = message.publish

    expect(result[:status]).to eq(:accepted)
    expect(result[:accepted]).to eq(true)
    expect(channel.exchange.published_options[:mandatory]).to eq(true)
    expect(channel.confirm_timeout).to eq(0.5)
  end

  it 'emits error headers from string-keyed error payloads' do
    message = Legion::LLM::Transport::Messages::FleetError.new(
      channel:              channel,
      reply_to:             'llm.fleet.reply.abc123',
      fleet_correlation_id: 'corr-1',
      error:                { 'code' => 'model_not_loaded' }
    )

    expect(message.headers['x-legion-fleet-error']).to eq('model_not_loaded')
  end
end
