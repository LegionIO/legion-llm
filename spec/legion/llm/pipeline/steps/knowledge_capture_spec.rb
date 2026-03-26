# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::KnowledgeCapture do
  let(:klass) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::KnowledgeCapture
      include Legion::LLM::Pipeline::Steps::PostResponse

      attr_accessor :request, :enrichments, :timeline, :warnings,
                    :raw_response, :resolved_provider, :resolved_model

      def initialize(request)
        @request           = request
        @enrichments       = {}
        @timeline          = Legion::LLM::Pipeline::Timeline.new
        @warnings          = []
        @raw_response      = nil
        @resolved_provider = :test
        @resolved_model    = 'test-model'
      end
    end
  end

  let(:request) do
    Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'How does X work?' }],
      routing:  { provider: :anthropic, model: 'test-model' }
    )
  end

  let(:executor) do
    ex = Legion::LLM::Pipeline::Executor.new(request)
    allow(ex).to receive(:step_provider_call).and_return(
      { role: :assistant, content: 'X works by doing Y' }
    )
    allow(ex).to receive(:step_response_normalization).and_return(nil)
    ex
  end

  describe '#step_knowledge_capture' do
    context 'when Apollo is not defined' do
      before do
        hide_const('Legion::Extensions::Apollo::Helpers::Writeback') if defined?(Legion::Extensions::Apollo::Helpers::Writeback)
      end

      it 'skips silently' do
        expect { executor.send(:step_knowledge_capture) }.not_to raise_error
      end
    end

    context 'when Apollo Writeback is defined' do
      before do
        stub_const('Legion::Extensions::Apollo::Helpers::Writeback', Module.new)
        allow(Legion::Extensions::Apollo::Helpers::Writeback).to receive(:evaluate_and_route)
      end

      it 'calls evaluate_and_route' do
        executor.call
        expect(Legion::Extensions::Apollo::Helpers::Writeback).to have_received(:evaluate_and_route)
      end
    end

    context 'when writeback raises an error' do
      before do
        stub_const('Legion::Extensions::Apollo::Helpers::Writeback', Module.new)
        allow(Legion::Extensions::Apollo::Helpers::Writeback).to receive(:evaluate_and_route)
          .and_raise(RuntimeError, 'boom')
      end

      it 'adds a warning instead of failing' do
        executor.call
        expect(executor.warnings).to include(match(/knowledge_capture error/))
      end
    end
  end

  describe '#step_knowledge_capture local ingest' do
    let(:local_request) do
      Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'test' }]
      )
    end

    it 'does not ingest to local when Legion::Apollo::Local is not started' do
      apollo_local = Module.new do
        def self.started? = false
        def self.ingest(**_) = raise('should not be called')
      end
      stub_const('Legion::Apollo::Local', apollo_local)

      step = klass.new(local_request)
      step.raw_response = double(content: 'response text', input_tokens: 10, output_tokens: 20)

      expect { step.step_knowledge_capture }.not_to raise_error
    end

    it 'ingests to local when Legion::Apollo::Local is started' do
      apollo_local = Module.new do
        def self.started? = true

        def self.ingest(**_kwargs)
          { success: true, mode: :local, id: 1 }
        end
      end
      stub_const('Legion::Apollo::Local', apollo_local)
      allow(apollo_local).to receive(:ingest).and_call_original

      step = klass.new(local_request)
      step.raw_response = double(content: 'response text', input_tokens: 10, output_tokens: 20)

      step.step_knowledge_capture
      expect(apollo_local).to have_received(:ingest).with(
        hash_including(content: 'response text', tags: array_including('llm_response'))
      )
    end

    it 'adds no warnings on successful local ingest' do
      apollo_local = Module.new do
        def self.started? = true
        def self.ingest(**_) = { success: true, mode: :local }
      end
      stub_const('Legion::Apollo::Local', apollo_local)

      step = klass.new(local_request)
      step.raw_response = double(content: 'answer', input_tokens: 5, output_tokens: 10)
      step.step_knowledge_capture
      expect(step.warnings.none? { |w| w.include?('local_knowledge') }).to be true
    end

    it 'adds a warning when local ingest raises' do
      apollo_local = Module.new do
        def self.started? = true
        def self.ingest(**_) = raise(StandardError, 'db locked')
      end
      stub_const('Legion::Apollo::Local', apollo_local)

      step = klass.new(local_request)
      step.raw_response = double(content: 'answer', input_tokens: 5, output_tokens: 10)
      step.step_knowledge_capture
      expect(step.warnings.any? { |w| w.include?('local_knowledge_capture') }).to be true
    end
  end
end
