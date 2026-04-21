# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/pipeline/timeline'
require 'legion/llm/pipeline/request'
require 'legion/llm/pipeline/steps'

RSpec.describe Legion::LLM::Pipeline::Steps::Debate do
  let(:host_class) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::Debate

      attr_accessor :request, :timeline, :warnings, :enrichments,
                    :raw_response, :resolved_model, :resolved_provider

      def initialize(request, raw_response = nil)
        @request           = request
        @timeline          = Legion::LLM::Pipeline::Timeline.new
        @warnings          = []
        @enrichments       = {}
        @raw_response      = raw_response
        @resolved_model    = nil
        @resolved_provider = nil
        @debate_settings   = nil
      end
    end
  end

  let(:base_request) do
    Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'What is the best approach to microservices?' }]
    )
  end

  let(:debate_request) do
    Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'What is the best approach to microservices?' }],
      extra:    { debate: true }
    )
  end

  let(:no_debate_request) do
    Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'What is the best approach to microservices?' }],
      extra:    { debate: false }
    )
  end

  let(:raw_response) do
    double('RawResponse', content: 'Microservices should be designed around business capabilities.')
  end

  let(:chat_direct_result) do
    { content: 'A debate role response.' }
  end

  before do
    Legion::Settings[:llm][:debate] = {
      enabled:                  false,
      gaia_auto_trigger:        false,
      default_rounds:           1,
      max_rounds:               3,
      advocate_model:           nil,
      challenger_model:         nil,
      judge_model:              nil,
      model_selection_strategy: 'rotate'
    }
    Legion::Settings[:llm][:providers] = {
      anthropic: { enabled: true, default_model: 'claude-sonnet-4-6' },
      openai:    { enabled: true, default_model: 'gpt-4o' },
      gemini:    { enabled: false, default_model: 'gemini-2.0-flash' }
    }
    allow(Legion::LLM).to receive(:chat_direct).and_return(chat_direct_result)
  end

  describe '#debate_enabled?' do
    context 'when request.extra[:debate] is true' do
      it 'returns true regardless of settings' do
        step = host_class.new(debate_request)
        expect(step.debate_enabled?(debate_request)).to be true
      end

      it 'returns true even when settings debate.enabled is false' do
        Legion::Settings[:llm][:debate][:enabled] = false
        step = host_class.new(debate_request)
        expect(step.debate_enabled?(debate_request)).to be true
      end
    end

    context 'when request.extra[:debate] is false' do
      it 'returns false even when settings say enabled' do
        Legion::Settings[:llm][:debate][:enabled] = true
        step = host_class.new(no_debate_request)
        expect(step.debate_enabled?(no_debate_request)).to be false
      end
    end

    context 'when request.extra[:debate] is not set' do
      it 'returns false when settings debate.enabled is false (default)' do
        step = host_class.new(base_request)
        expect(step.debate_enabled?(base_request)).to be false
      end

      it 'returns true when settings debate.enabled is true' do
        Legion::Settings[:llm][:debate][:enabled] = true
        step = host_class.new(base_request)
        expect(step.debate_enabled?(base_request)).to be true
      end
    end
  end

  describe '#gaia_debate_trigger?' do
    it 'returns false when gaia_auto_trigger is false (default)' do
      step = host_class.new(base_request)
      enrichments = { 'gaia:advisory' => { data: { high_stakes: true } } }
      expect(step.gaia_debate_trigger?(enrichments)).to be false
    end

    it 'returns false when gaia_auto_trigger is true but advisory does not flag high_stakes' do
      Legion::Settings[:llm][:debate][:gaia_auto_trigger] = true
      step = host_class.new(base_request)
      enrichments = { 'gaia:advisory' => { data: { high_stakes: false } } }
      expect(step.gaia_debate_trigger?(enrichments)).to be false
    end

    it 'returns true when gaia_auto_trigger is true and high_stakes is flagged' do
      Legion::Settings[:llm][:debate][:gaia_auto_trigger] = true
      step = host_class.new(base_request)
      enrichments = { 'gaia:advisory' => { data: { high_stakes: true } } }
      expect(step.gaia_debate_trigger?(enrichments)).to be true
    end

    it 'returns true when gaia_auto_trigger is true and debate_recommended is flagged' do
      Legion::Settings[:llm][:debate][:gaia_auto_trigger] = true
      step = host_class.new(base_request)
      enrichments = { 'gaia:advisory' => { data: { debate_recommended: true } } }
      expect(step.gaia_debate_trigger?(enrichments)).to be true
    end

    it 'returns false when enrichments are nil' do
      Legion::Settings[:llm][:debate][:gaia_auto_trigger] = true
      step = host_class.new(base_request)
      expect(step.gaia_debate_trigger?(nil)).to be false
    end

    it 'returns false when enrichments are empty' do
      Legion::Settings[:llm][:debate][:gaia_auto_trigger] = true
      step = host_class.new(base_request)
      expect(step.gaia_debate_trigger?({})).to be false
    end
  end

  describe '#step_debate' do
    context 'when debate is disabled' do
      it 'is a no-op and does not call chat_direct' do
        step = host_class.new(base_request, raw_response)
        step.step_debate
        expect(Legion::LLM).not_to have_received(:chat_direct)
        expect(step.raw_response).to eq(raw_response)
        expect(step.enrichments).not_to have_key('debate:result')
      end
    end

    context 'when debate is enabled via request.extra' do
      it 'runs debate and replaces raw_response with judge synthesis' do
        step = host_class.new(debate_request, raw_response)
        step.step_debate
        expect(step.raw_response).to respond_to(:content)
        expect(step.raw_response.content).to eq('A debate role response.')
      end

      it 'populates enrichments with debate result' do
        step = host_class.new(debate_request, raw_response)
        step.step_debate
        expect(step.enrichments).to have_key('debate:result')
        expect(step.enrichments['debate:result'][:data]).to include(:enabled, :rounds, :advocate_model, :challenger_model, :judge_model)
      end

      it 'records a timeline event' do
        step = host_class.new(debate_request, raw_response)
        step.step_debate
        keys = step.timeline.events.map { |e| e[:key] }
        expect(keys).to include('debate:completed')
      end

      it 'calls chat_direct for challenger, rebuttal, and judge roles (3 calls for 1 round)' do
        step = host_class.new(debate_request, raw_response)
        step.step_debate
        # 1 round: challenger + rebuttal + judge = 3 calls
        expect(Legion::LLM).to have_received(:chat_direct).exactly(3).times
      end
    end

    context 'when debate is enabled via settings' do
      before { Legion::Settings[:llm][:debate][:enabled] = true }

      it 'runs debate when no explicit flag is set' do
        step = host_class.new(base_request, raw_response)
        step.step_debate
        expect(step.enrichments).to have_key('debate:result')
      end
    end

    context 'when raw_response is nil' do
      it 'skips debate entirely' do
        step = host_class.new(debate_request, nil)
        step.step_debate
        expect(Legion::LLM).not_to have_received(:chat_direct)
      end
    end

    context 'when a debate role call fails' do
      it 'does not raise and still produces a response (role error is captured in content)' do
        allow(Legion::LLM).to receive(:chat_direct).and_raise(StandardError, 'network error')
        step = host_class.new(debate_request, raw_response)
        expect { step.step_debate }.not_to raise_error
        # Role errors are absorbed into placeholder content; debate still completes
        expect(step.enrichments).to have_key('debate:result')
      end
    end

    context 'when run_debate itself raises an unexpected error' do
      it 'adds warning and does not raise' do
        allow_any_instance_of(host_class).to receive(:run_debate).and_raise(StandardError, 'unexpected')
        step = host_class.new(debate_request, raw_response)
        expect { step.step_debate }.not_to raise_error
        expect(step.warnings).to include(match(/debate step error: unexpected/))
      end
    end
  end

  describe 'debate rounds' do
    it 'defaults to 1 round' do
      step = host_class.new(debate_request, raw_response)
      step.step_debate
      expect(step.enrichments['debate:result'][:data][:rounds]).to eq(1)
    end

    it 'respects debate_rounds from request extra' do
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'question' }],
        extra:    { debate: true, debate_rounds: 2 }
      )
      step = host_class.new(request, raw_response)
      step.step_debate
      expect(step.enrichments['debate:result'][:data][:rounds]).to eq(2)
      # 2 rounds: (challenger + rebuttal) * 2 + judge = 5 calls
      expect(Legion::LLM).to have_received(:chat_direct).exactly(5).times
    end

    it 'caps rounds at max_rounds setting' do
      Legion::Settings[:llm][:debate][:max_rounds] = 2
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'question' }],
        extra:    { debate: true, debate_rounds: 10 }
      )
      step = host_class.new(request, raw_response)
      step.step_debate
      expect(step.enrichments['debate:result'][:data][:rounds]).to eq(2)
    end

    it 'enforces minimum of 1 round even if 0 is requested' do
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'question' }],
        extra:    { debate: true, debate_rounds: 0 }
      )
      step = host_class.new(request, raw_response)
      step.step_debate
      expect(step.enrichments['debate:result'][:data][:rounds]).to eq(1)
    end
  end

  describe 'model selection' do
    it 'uses different models for advocate, challenger, and judge' do
      step = host_class.new(debate_request, raw_response)
      step.step_debate
      metadata = step.enrichments['debate:result'][:data]
      expect(metadata[:challenger_model]).not_to eq(metadata[:advocate_model])
      expect(metadata[:judge_model]).not_to eq(metadata[:advocate_model])
    end

    it 'uses explicitly configured models from settings' do
      Legion::Settings[:llm][:debate][:advocate_model]   = 'anthropic:claude-sonnet-4-6'
      Legion::Settings[:llm][:debate][:challenger_model] = 'openai:gpt-4o'
      Legion::Settings[:llm][:debate][:judge_model]      = 'anthropic:claude-sonnet-4-5'

      step = host_class.new(debate_request, raw_response)
      step.step_debate
      metadata = step.enrichments['debate:result'][:data]
      expect(metadata[:advocate_model]).to eq('anthropic:claude-sonnet-4-6')
      expect(metadata[:challenger_model]).to eq('openai:gpt-4o')
      expect(metadata[:judge_model]).to eq('anthropic:claude-sonnet-4-5')
    end

    it 'degrades gracefully when only one model is available' do
      Legion::Settings[:llm][:providers] = {
        anthropic: { enabled: true, default_model: 'claude-sonnet-4-6' },
        openai:    { enabled: false, default_model: 'gpt-4o' }
      }
      step = host_class.new(debate_request, raw_response)
      step.step_debate
      expect(step.warnings).to include(match(/fewer than 2 models available/))
      expect(step.enrichments).to have_key('debate:result')
    end
  end

  describe 'judge synthesis replaces response' do
    it 'sets raw_response.content to the judge output' do
      allow(Legion::LLM).to receive(:chat_direct).and_return({ content: 'judge final answer' })
      step = host_class.new(debate_request, raw_response)
      step.step_debate
      expect(step.raw_response.content).to eq('judge final answer')
    end

    it 'debate metadata includes advocate_summary and challenger_summary' do
      step = host_class.new(debate_request, raw_response)
      step.step_debate
      metadata = step.enrichments['debate:result'][:data]
      expect(metadata).to have_key(:advocate_summary)
      expect(metadata).to have_key(:challenger_summary)
    end
  end

  describe 'GAIA auto-trigger' do
    before { Legion::Settings[:llm][:debate][:gaia_auto_trigger] = true }

    it 'triggers debate when GAIA marks response as high_stakes' do
      step = host_class.new(base_request, raw_response)
      step.enrichments['gaia:advisory'] = { data: { high_stakes: true } }
      step.step_debate
      expect(step.enrichments).to have_key('debate:result')
    end

    it 'does not trigger when GAIA advisory is absent' do
      step = host_class.new(base_request, raw_response)
      step.step_debate
      expect(step.enrichments).not_to have_key('debate:result')
    end
  end

  describe 'GAIA auto-trigger disabled by default' do
    it 'does not auto-trigger even with high_stakes enrichment when gaia_auto_trigger is false' do
      step = host_class.new(base_request, raw_response)
      step.enrichments['gaia:advisory'] = { data: { high_stakes: true } }
      step.step_debate
      expect(step.enrichments).not_to have_key('debate:result')
      expect(Legion::LLM).not_to have_received(:chat_direct)
    end
  end

  describe 'default behavior unchanged when debate disabled' do
    it 'does not modify raw_response when debate is off' do
      step = host_class.new(base_request, raw_response)
      original_response = step.raw_response
      step.step_debate
      expect(step.raw_response).to equal(original_response)
    end

    it 'does not add enrichments when debate is off' do
      step = host_class.new(base_request, raw_response)
      step.step_debate
      expect(step.enrichments).to be_empty
    end

    it 'does not add timeline events when debate is off' do
      step = host_class.new(base_request, raw_response)
      step.step_debate
      expect(step.timeline.events).to be_empty
    end
  end

  describe 'chat_direct calls use correct provider/model split' do
    it 'parses provider:model format when calling roles' do
      Legion::Settings[:llm][:debate][:challenger_model] = 'openai:gpt-4o'
      Legion::Settings[:llm][:debate][:judge_model]      = 'anthropic:claude-sonnet-4-5'

      step = host_class.new(debate_request, raw_response)
      step.step_debate

      expect(Legion::LLM).to have_received(:chat_direct).with(
        hash_including(model: 'gpt-4o', provider: :openai)
      ).at_least(:once)
      expect(Legion::LLM).to have_received(:chat_direct).with(
        hash_including(model: 'claude-sonnet-4-5', provider: :anthropic)
      ).at_least(:once)
    end
  end
end
