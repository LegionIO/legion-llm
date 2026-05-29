# frozen_string_literal: true

require 'spec_helper'
require 'sinatra/base'

RSpec.describe 'Legion::LLM::API::Namespaces::Registration' do
  before do
    require 'legion/llm/api/namespaces/registration'
  end

  let(:app) { Class.new(Sinatra::Base) }

  describe '.registered' do
    it 'registers Sinatra::Namespace on the app' do
      Legion::LLM::API::Namespaces::Registration.registered(app)
      expect(app.extensions).to include(Sinatra::Namespace)
    end

    it 'includes Namespaces::Helpers on the app' do
      Legion::LLM::API::Namespaces::Registration.registered(app)
      test_app = app.new!
      expect(test_app).to respond_to(:parse_request_body)
      expect(test_app).to respond_to(:require_llm!)
      expect(test_app).to respond_to(:detect_client)
    end
  end

  describe 'register_openai' do
    before do
      allow(Legion::LLM).to receive(:started?).and_return(true)
    end

    it 'mounts all OpenAI routes on the app' do
      Legion::LLM::API::Namespaces::Registration.registered(app)

      routes = app.routes
      post_paths = (routes['POST'] || []).map { |r| r[0].to_s }
      get_paths  = (routes['GET']  || []).map { |r| r[0].to_s }

      expect(post_paths.any? { |p| p.include?('responses') }).to be(true)
      expect(post_paths.any? { |p| p.include?('chat') && p.include?('completions') }).to be(true)
      expect(get_paths.any?  { |p| p.include?('models') }).to be(true)
      expect(post_paths.any? { |p| p.include?('embeddings') }).to be(true)
    end
  end
end
