# frozen_string_literal: true

require 'spec_helper'

# Stub Legion::Transport base classes for standalone testing
unless defined?(Legion::Transport::Exchange)
  module Legion
    module Transport
      class Exchange
        def self.exchange_name(name = nil)
          @exchange_name = name if name
          @exchange_name
        end

        def self.exchange_type(type = nil)
          @exchange_type = type if type
          @exchange_type
        end
      end

      class Message
        def self.routing_key(key = nil)
          @routing_key = key if key
          @routing_key
        end
      end
    end
  end
  $LOADED_FEATURES << 'legion/transport'
end

require 'legion/llm/transport/exchanges/escalation'
require 'legion/llm/transport/messages/escalation_event'

RSpec.describe Legion::LLM::Transport::Exchanges::Escalation do
  it 'defines the exchange name' do
    expect(described_class.exchange_name).to eq('llm.escalation')
  end

  it 'uses topic exchange type' do
    expect(described_class.exchange_type).to eq(:topic)
  end
end

RSpec.describe Legion::LLM::Transport::Messages::EscalationEvent do
  it 'defines the routing key' do
    expect(described_class.routing_key).to eq('llm.escalation.completed')
  end
end
