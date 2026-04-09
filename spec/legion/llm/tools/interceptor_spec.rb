# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/tools/interceptor'

RSpec.describe Legion::LLM::Tools::Interceptor do
  before { described_class.reset! }
  after  { described_class.reset! }

  describe '.register / .registered' do
    it 'registers a named interceptor' do
      described_class.register(:test, matcher: ->(_) { true }) { |_name, **args| args }
      expect(described_class.registered).to eq([:test])
    end
  end

  describe '.intercept' do
    it 'returns args unchanged when no interceptors match' do
      described_class.register(:nope, matcher: ->(_) { false }) { |_name, **args| args }
      result = described_class.intercept('python', command: 'python3 hello.py')
      expect(result[:command]).to eq('python3 hello.py')
    end

    it 'rewrites args when an interceptor matches' do
      described_class.register(:upper, matcher: ->(name) { name == 'test' }) do |_name, **args|
        args.merge(command: args[:command].upcase)
      end
      result = described_class.intercept('test', command: 'hello')
      expect(result[:command]).to eq('HELLO')
    end

    it 'chains multiple matching interceptors' do
      described_class.register(:add_a, matcher: ->(_) { true }) do |_name, **args|
        args.merge(command: "#{args[:command]}A")
      end
      described_class.register(:add_b, matcher: ->(_) { true }) do |_name, **args|
        args.merge(command: "#{args[:command]}B")
      end
      result = described_class.intercept('any', command: '')
      expect(result[:command]).to eq('AB')
    end
  end

  describe '.reset!' do
    it 'clears all registered interceptors' do
      described_class.register(:foo, matcher: ->(_) { true }) { |_name, **args| args }
      described_class.reset!
      expect(described_class.registered).to be_empty
    end
  end
end
