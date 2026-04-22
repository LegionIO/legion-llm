# frozen_string_literal: true

require 'spec_helper'

# Stub Legion::Transport base classes for standalone testing
unless defined?(Legion::Transport::Exchange)
  module Legion
    module Transport
      class Exchange
        def exchange_name
          self.class.name.split('::').last.downcase
        end

        def default_type
          'topic'
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

unless defined?(Legion::LLM::Transport::Message)
  module Legion
    module LLM
      module Transport
        class Message < ::Legion::Transport::Message
        end
      end
    end
  end
end

require 'legion/llm/transport/exchanges/escalation'
require 'legion/llm/transport/messages/escalation_event'

RSpec.describe Legion::LLM::Transport::Exchanges::Escalation do
  subject(:exchange) { described_class.allocate }

  it 'returns the correct exchange name' do
    expect(exchange.exchange_name).to eq('llm.escalation')
  end

  it 'uses topic as default type' do
    expect(exchange.default_type).to eq('topic')
  end
end

RSpec.describe Legion::LLM::Transport::Messages::EscalationEvent do
  it 'defines the routing key' do
    expect(described_class.routing_key).to eq('llm.escalation.completed')
  end
end
