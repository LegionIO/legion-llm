# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module CompatWarning
      extend Legion::Logging::Helper

      def self.warn_once(old_name, new_name)
        @warned ||= {}
        return if @warned[old_name]

        @warned[old_name] = true
        location = caller_locations(2, 1)&.first
        msg = "[DEPRECATION] #{old_name} is deprecated, use #{new_name} instead"
        msg += " (called from #{location})" if location
        log.warn(msg)
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'llm.compat.warn_once')
        warn msg
      end
    end

    def self.const_missing(name)
      case name
      when :Discovery
        # Moved to Legion::LLM::Inventory::Discovery in v0.14.0
        CompatWarning.warn_once('Legion::LLM::Discovery', 'Legion::LLM::Inventory::Discovery')
        Inventory::Discovery
      when :Capabilities
        # Moved to Legion::LLM::Inventory::Capabilities in v0.14.0
        CompatWarning.warn_once('Legion::LLM::Capabilities', 'Legion::LLM::Inventory::Capabilities')
        Inventory::Capabilities
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
        raise NameError, 'Legion::LLM::NativeResponseAdapter removed in v0.12.x — use Canonical::Response from lex-llm'
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
      when :DaemonClient
        CompatWarning.warn_once('Legion::LLM::DaemonClient', 'Legion::LLM::Call::DaemonClient')
        Call::DaemonClient
      when :Providers
        CompatWarning.warn_once('Legion::LLM::Providers', 'Legion::LLM::Call::Providers')
        Call::Providers
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

    # Discovery moved to Legion::LLM::Inventory::Discovery in v0.14.0.
    # rule_generator.rb defines Legion::LLM::Discovery as a real module (not via const_missing).
    # Add System/MemoryGate const aliases and method_missing delegation so callers keep working.
    if defined?(Legion::LLM::Discovery) && defined?(Legion::LLM::Inventory::Discovery)
      # Mirror nested constants used by callers
      %i[System MemoryGate].each do |cname|
        Legion::LLM::Discovery.const_set(cname, Legion::LLM::Inventory::Discovery.const_get(cname)) unless Legion::LLM::Discovery.const_defined?(cname, false)
      end
      # Mirror module-level constants used in specs
      %i[EMBEDDING_TIER_ORDER MODEL_FAMILY_DELIMITERS MODEL_DIVERGENCE_SAMPLE_SIZE].each do |cname|
        Legion::LLM::Discovery.const_set(cname, Legion::LLM::Inventory::Discovery.const_get(cname)) unless Legion::LLM::Discovery.const_defined?(cname, false)
      end
      # Forward all method calls (incl private, for .send) to Inventory::Discovery
      Legion::LLM::Discovery.singleton_class.define_method(:method_missing) do |name, *args, **kwargs, &block|
        target = Legion::LLM::Inventory::Discovery
        target.respond_to?(name, true) ? target.send(name, *args, **kwargs, &block) : super(name, *args, **kwargs, &block)
      end
      Legion::LLM::Discovery.singleton_class.define_method(:respond_to_missing?) do |name, include_private = false|
        Legion::LLM::Inventory::Discovery.respond_to?(name, include_private) || super(name, include_private)
      end
      # Forward instance_variable_set/get to Inventory::Discovery so test setup that
      # sets @discovered_models etc. on Discovery actually affects the real module.
      Legion::LLM::Discovery.singleton_class.define_method(:instance_variable_set) do |name, value|
        Legion::LLM::Inventory::Discovery.instance_variable_set(name, value)
      end
      Legion::LLM::Discovery.singleton_class.define_method(:instance_variable_get) do |name|
        Legion::LLM::Inventory::Discovery.instance_variable_get(name)
      end
    end
  end
end
