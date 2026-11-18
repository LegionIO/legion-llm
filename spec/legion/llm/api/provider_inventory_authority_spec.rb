# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/native/providers'
require 'legion/llm/api/namespaces/native/providers'

RSpec.describe 'Provider API inventory authority', :ssot_v3 do
  include Rack::Test::Methods

  %i[flat namespaced].each do |registration|
    context "#{registration} routes" do
      let(:app) do
        mode = registration
        Class.new(Sinatra::Base) do
          set :host_authorization, permitted: :any
          helpers Legion::LLM::API::Namespaces::Helpers
          if mode == :namespaced
            register Sinatra::Namespace
            namespace '/api/llm/providers' do
              register Legion::LLM::API::Namespaces::Native::Providers
            end
          else
            register Legion::LLM::API::Native::Providers
          end
        end
      end

      before do
        allow(Legion::LLM).to receive(:started?).and_return(true)
        allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([
                                                                                   { provider: :azure_foundry, instance: :pending, metadata: { tier: :cloud } }
                                                                                 ])
        claim_only(provider_family: 'azure_foundry', instance_id: 'pending')
        activate(provider_family: 'vllm', instance_id: 'ready', drafts: [
                   offering_draft(model: 'chat-model', supported: %i[chat stream_chat], capabilities: { tools: :supported }),
                   offering_draft(model: 'embedding-model', supported: %i[embed], capabilities: { embedding: :supported })
                 ])
      end

      it 'lists only published instances and projects their complete authoritative health' do
        get '/api/llm/providers'

        expect(last_response.status).to eq(200)
        data = Legion::JSON.load(last_response.body).fetch(:data)
        expect(data[:providers].map { |entry| [entry[:provider], entry[:instance]] }).to eq([%w[vllm ready]])
        record = snapshot.instance(instance_key: instance_key(provider_family: 'vllm', instance_id: 'ready'))
        health = record.availability
        expect(data[:providers].first[:health]).to eq(
          state: health.state.to_s, reason: health.reason, observed_at: health.observed_at.iso8601,
          last_probe_outcome: health.last_probe_outcome.to_s, source: health.source.to_s
        )
        expect(data[:summary]).to eq(total: 1, native: 1, routing_enabled: true)
      end

      it 'uses the same catalog for family routes and unions capability evidence across offerings' do
        get '/api/llm/providers/vllm'

        expect(last_response.status).to eq(200)
        instances = Legion::JSON.load(last_response.body).dig(:data, :instances)
        expect(instances.size).to eq(1)
        expect(instances.first[:capabilities]).to include('tools', 'embedding')
      end

      it 'surfaces snapshot faults rather than substituting configuration entries' do
        allow(Legion::Extensions::Llm::Inventory::Registry).to receive(:snapshot).and_raise(IOError, 'inventory read failed')

        get '/api/llm/providers'

        expect(last_response.status).to eq(500)
        expect(Legion::JSON.load(last_response.body).dig(:error, :code)).to eq('provider_error')
      end
    end
  end
end
