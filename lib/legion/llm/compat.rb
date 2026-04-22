# frozen_string_literal: true

module Legion
  module LLM
    module CompatWarning
      def self.warn_once(old_name, new_name)
        @warned ||= {}
        return if @warned[old_name]

        @warned[old_name] = true
        location = caller_locations(2, 1)&.first
        msg = "[DEPRECATION] #{old_name} is deprecated, use #{new_name} instead"
        msg += " (called from #{location})" if location
        if defined?(Legion::Logging)
          Legion::Logging.warn(msg)
        else
          warn msg
        end
      end
    end

    def self.const_missing(name) # rubocop:disable Metrics/MethodLength
      case name
      when :Pipeline
        CompatWarning.warn_once('Legion::LLM::Pipeline', 'Legion::LLM::Inference')
        Inference
      when :ConversationStore
        CompatWarning.warn_once('Legion::LLM::ConversationStore', 'Legion::LLM::Inference::Conversation')
        Inference::Conversation
      when :NativeDispatch
        CompatWarning.warn_once('Legion::LLM::NativeDispatch', 'Legion::LLM::Call::Dispatch')
        Call::Dispatch
      when :NativeResponseAdapter
        CompatWarning.warn_once('Legion::LLM::NativeResponseAdapter', 'Legion::LLM::Call::NativeResponseAdapter')
        Call::NativeResponseAdapter
      when :ProviderRegistry
        CompatWarning.warn_once('Legion::LLM::ProviderRegistry', 'Legion::LLM::Call::Registry')
        Call::Registry
      when :CostEstimator
        CompatWarning.warn_once('Legion::LLM::CostEstimator', 'Legion::LLM::Metering::Pricing')
        Metering::Pricing
      when :CostTracker
        CompatWarning.warn_once('Legion::LLM::CostTracker', 'Legion::LLM::Metering::Recorder')
        Metering::Recorder
      when :TokenTracker
        CompatWarning.warn_once('Legion::LLM::TokenTracker', 'Legion::LLM::Metering::Tokens')
        Metering::Tokens
      when :QualityChecker
        CompatWarning.warn_once('Legion::LLM::QualityChecker', 'Legion::LLM::Quality::Checker')
        Quality::Checker
      when :ConfidenceScorer
        CompatWarning.warn_once('Legion::LLM::ConfidenceScorer', 'Legion::LLM::Quality::Confidence::Scorer')
        Quality::Confidence::Scorer
      when :ConfidenceScore
        CompatWarning.warn_once('Legion::LLM::ConfidenceScore', 'Legion::LLM::Quality::Confidence::Score')
        Quality::Confidence::Score
      when :OverrideConfidence
        CompatWarning.warn_once('Legion::LLM::OverrideConfidence', 'Legion::LLM::Tools::Confidence')
        Tools::Confidence
      when :ResponseCache
        CompatWarning.warn_once('Legion::LLM::ResponseCache', 'Legion::LLM::Cache::Response')
        Cache::Response
      when :Compressor
        CompatWarning.warn_once('Legion::LLM::Compressor', 'Legion::LLM::Context::Compressor')
        Context::Compressor
      when :ClaudeConfigLoader
        CompatWarning.warn_once('Legion::LLM::ClaudeConfigLoader', 'Legion::LLM::Call::ClaudeConfigLoader')
        Call::ClaudeConfigLoader
      when :CodexConfigLoader
        CompatWarning.warn_once('Legion::LLM::CodexConfigLoader', 'Legion::LLM::Call::CodexConfigLoader')
        Call::CodexConfigLoader
      when :DaemonClient
        CompatWarning.warn_once('Legion::LLM::DaemonClient', 'Legion::LLM::Call::DaemonClient')
        Call::DaemonClient
      when :Providers
        CompatWarning.warn_once('Legion::LLM::Providers', 'Legion::LLM::Call::Providers')
        Call::Providers
      when :Settings
        Config::Settings
      when :Prompt
        CompatWarning.warn_once('Legion::LLM::Prompt', 'Legion::LLM::Inference::Prompt')
        Inference::Prompt
      when :ShadowEval
        CompatWarning.warn_once('Legion::LLM::ShadowEval', 'Legion::LLM::Quality::ShadowEval')
        Quality::ShadowEval
      when :Arbitrage
        CompatWarning.warn_once('Legion::LLM::Arbitrage', 'Legion::LLM::Router::Arbitrage')
        Router::Arbitrage
      when :Batch
        CompatWarning.warn_once('Legion::LLM::Batch', 'Legion::LLM::Scheduling::Batch')
        Scheduling::Batch
      when :ContextCurator
        CompatWarning.warn_once('Legion::LLM::ContextCurator', 'Legion::LLM::Context::Curator')
        Context::Curator
      when :Embeddings
        CompatWarning.warn_once('Legion::LLM::Embeddings', 'Legion::LLM::Call::Embeddings')
        Call::Embeddings
      when :OffPeak
        CompatWarning.warn_once('Legion::LLM::OffPeak', 'Legion::LLM::Scheduling::OffPeak')
        Scheduling::OffPeak
      when :InferenceError
        CompatWarning.warn_once('Legion::LLM::InferenceError', 'Legion::LLM::PipelineError')
        PipelineError
      when :Routes, :API
        require_relative '../llm/api'
        const_get(name)
      else
        super
      end
    end
  end
end
