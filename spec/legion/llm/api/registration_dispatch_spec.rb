# frozen_string_literal: true

require 'spec_helper'
require 'sinatra/base'

RSpec.describe Legion::LLM::API do
  let(:app) { Class.new(Sinatra::Base) }

  after do
    Legion::LLM::Settings.register_defaults!
  end

  describe '.registered' do
    context 'when use_namespaces is unset (default true)' do
      before do
        allow(Legion::Settings).to receive(:dig)
          .with(:llm, :api, :use_namespaces)
          .and_return(nil)
      end

      it 'calls Namespaces::Registration and skips legacy chain' do
        expect(Legion::LLM::API::Namespaces::Registration).to receive(:registered).with(app)
        expect(Legion::LLM::API::Auth).not_to receive(:registered)
        expect(Legion::LLM::API::Native::Inference).not_to receive(:registered)
        Legion::LLM::API.registered(app)
      end
    end

    context 'when use_namespaces is true' do
      before do
        allow(Legion::Settings).to receive(:dig)
          .with(:llm, :api, :use_namespaces)
          .and_return(true)
      end

      it 'calls Namespaces::Registration and skips legacy chain' do
        expect(Legion::LLM::API::Namespaces::Registration).to receive(:registered).with(app)
        expect(Legion::LLM::API::Auth).not_to receive(:registered)
        expect(Legion::LLM::API::Native::Inference).not_to receive(:registered)
        Legion::LLM::API.registered(app)
      end
    end

    context 'when use_namespaces is false (deprecated legacy opt-in)' do
      before do
        allow(Legion::Settings).to receive(:dig)
          .with(:llm, :api, :use_namespaces)
          .and_return(false)
      end

      it 'calls legacy flat registration chain' do
        expect(Legion::LLM::API::Auth).to receive(:registered).with(app)
        expect(Legion::LLM::API::Native::Helpers).to receive(:registered).with(app)
        expect(Legion::LLM::API::Native::Inference).to receive(:registered).with(app)
        expect(Legion::LLM::API::Native::Chat).to receive(:registered).with(app)
        expect(Legion::LLM::API::Native::Providers).to receive(:registered).with(app)
        expect(Legion::LLM::API::Native::Models).to receive(:registered).with(app)
        expect(Legion::LLM::API::Native::Offerings).to receive(:registered).with(app)
        expect(Legion::LLM::API::Native::Instances).to receive(:registered).with(app)
        expect(Legion::LLM::API::Native::Routing).to receive(:registered).with(app)
        expect(Legion::LLM::API::Native::Tiers).to receive(:registered).with(app)
        expect(Legion::LLM::API::OpenAI::ChatCompletions).to receive(:registered).with(app)
        expect(Legion::LLM::API::OpenAI::Models).to receive(:registered).with(app)
        expect(Legion::LLM::API::OpenAI::Embeddings).to receive(:registered).with(app)
        expect(Legion::LLM::API::OpenAI::Responses).to receive(:registered).with(app)
        expect(Legion::LLM::API::Anthropic::Messages).to receive(:registered).with(app)
        Legion::LLM::API.registered(app)
      end

      it 'emits a deprecation log.warn before registering the legacy chain' do
        [
          Legion::LLM::API::Auth,
          Legion::LLM::API::Native::Helpers,
          Legion::LLM::API::Native::Inference,
          Legion::LLM::API::Native::Chat,
          Legion::LLM::API::Native::Providers,
          Legion::LLM::API::Native::Models,
          Legion::LLM::API::Native::Offerings,
          Legion::LLM::API::Native::Instances,
          Legion::LLM::API::Native::Routing,
          Legion::LLM::API::Native::Tiers,
          Legion::LLM::API::OpenAI::ChatCompletions,
          Legion::LLM::API::OpenAI::Models,
          Legion::LLM::API::OpenAI::Embeddings,
          Legion::LLM::API::OpenAI::Responses,
          Legion::LLM::API::Anthropic::Messages
        ].each { |mod| allow(mod).to receive(:registered) }

        expect(Legion::LLM::API.log).to receive(:warn).with(a_string_including('DEPRECATED'))
        expect(Legion::LLM::API::Namespaces::Registration).not_to receive(:registered)
        Legion::LLM::API.registered(app)
      end
    end
  end

  describe '.register_routes' do
    it 'delegates to Legion::API.register_library_routes when available' do
      fake_legion_api = double('Legion::API', register_library_routes: nil)
      stub_const('Legion::API', fake_legion_api)
      allow(fake_legion_api).to receive(:respond_to?).with(:register_library_routes).and_return(true)
      expect(fake_legion_api).to receive(:register_library_routes).with('llm', Legion::LLM::API)
      Legion::LLM::API.register_routes
    end

    it 'is a no-op when Legion::API is absent' do
      hide_const('Legion::API')
      expect { Legion::LLM::API.register_routes }.not_to raise_error
    end
  end
end
