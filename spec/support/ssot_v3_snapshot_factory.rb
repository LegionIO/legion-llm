# frozen_string_literal: true

# SSOT v3 test substrate (Phase 2, Task 1).
#
# Publishes real instances/offerings through the released Phase 1 lex-llm
# Registry API and returns the resulting immutable Snapshot. It NEVER
# instantiates Snapshot/InstanceRecord/OfferingRecord/LaneRecord directly and
# defines no fake runtime classes. Every router spec ranks/rejects against a
# snapshot produced here so fixtures cannot drift from the real contract.
#
# Canonical released path note: InstanceKey lives at
# Inventory::Identity::InstanceKey (not Inventory::InstanceKey).
module SsotV3SnapshotFactory
  module_function

  def inventory
    Legion::Extensions::Llm::Inventory
  end

  def instance_key(provider_family:, instance_id:)
    inventory::Identity::InstanceKey.new(provider_family: provider_family, instance_id: instance_id)
  end

  # A distinct provider callable. Records inference vs readiness separately so
  # specs can prove safe readiness performs no inference.
  class FactoryCallable
    attr_reader :inference_calls, :disconnects

    def initialize(responder: nil)
      @inference_calls = 0
      @disconnects = 0
      @responder = responder
    end

    def disconnect
      @disconnects += 1
      nil
    end

    def control_plane_ready?
      true
    end

    %i[chat stream_chat embed image transcribe translate speak moderate count_tokens].each do |op|
      define_method(op) do |*args, **kwargs, &block|
        @inference_calls += 1
        return @responder.call(op, args, kwargs, block) if @responder

        { ok: true, op: op }
      end
    end
  end

  def unknown_value
    inventory::ValueEvidence.new(status: :unknown, source: :absent)
  end

  def known_value(value)
    inventory::ValueEvidence.new(status: :known, value: value, source: :provider_catalog)
  end

  # Build operation evidence for a complete OPERATIONS hash.
  # supported: array of canonical operations with authoritative supported evidence.
  # unsupported: array with authoritative unsupported evidence.
  # everything else is unknown/absent.
  def operation_evidence(supported: %i[chat], unsupported: [])
    Legion::Extensions::Llm::Taxonomies::OPERATIONS.to_h do |op|
      status, source =
        if supported.include?(op)
          %i[supported provider_implementation]
        elsif unsupported.include?(op)
          %i[unsupported provider_implementation]
        else
          %i[unknown absent]
        end
      [op, inventory::OperationEvidence.new(operation: op, status: status, source: source)]
    end
  end

  # capabilities: { streaming: :supported, tools: :unsupported, vision: :unknown, ... }
  def capability_evidence(capabilities)
    capabilities.to_h do |cap, status|
      source = status == :unknown ? :absent : :provider_implementation
      canonical = Legion::Extensions::Llm::Capabilities.canonical(cap)
      [canonical, inventory::CapabilityEvidence.new(capability: canonical, status: status, source: source)]
    end
  end

  # Build a single OfferingDraft. Pass explicit evidence via kwargs or defaults.
  def offering_draft(
    model:, native: nil, tier: :local, supported: %i[chat], unsupported: [],
    capabilities: {}, context: nil, max_output: nil, embedding_dimensions: nil,
    model_revision: nil, tokenizer: nil, quota_domains: {}, metadata: {}
  )
    inventory::OfferingDraft.new(
      provider_native_key: native || model,
      model: model,
      tier: tier,
      operation_evidence: operation_evidence(supported: supported, unsupported: unsupported),
      capability_evidence: capability_evidence(capabilities),
      context_evidence: context.nil? ? unknown_value : known_value(context),
      max_output_evidence: max_output.nil? ? unknown_value : known_value(max_output),
      embedding_dimensions_evidence: embedding_dimensions.nil? ? unknown_value : known_value(embedding_dimensions),
      model_revision_evidence: model_revision.nil? ? unknown_value : known_value(model_revision),
      tokenizer_evidence: tokenizer.nil? ? unknown_value : known_value(tokenizer),
      quota_domains: quota_domains,
      metadata: metadata,
      publication_source: :provider_catalog
    )
  end

  # Claim + immediate-startup readiness + atomic activation for one instance.
  # Returns the PublisherToken. drafts is an Array<OfferingDraft>.
  def activate(provider_family:, instance_id:, drafts:, sequence: 0, callable: nil, coordinator: nil)
    key = instance_key(provider_family: provider_family, instance_id: instance_id)
    callable ||= FactoryCallable.new
    coordinator ||= inventory::ProbeCoordinator.new(instance_key: key, enqueue: ->(**) { true })
    token = inventory::Registry.claim_instance(
      instance_key: key, callable: callable, probe_request_handle: coordinator
    )
    probe = inventory::Registry.readiness_probe_started(instance_key: key, publisher_token: token)
    inventory::Registry.activate_instance_snapshot(
      publisher_token: token, instance_key: key, offerings: Array(drafts), sequence: sequence, probe_token: probe
    )
    token
  end

  # Claim only (no activation): leaves the instance initializing/selector-invisible.
  def claim_only(provider_family:, instance_id:, callable: nil, coordinator: nil)
    key = instance_key(provider_family: provider_family, instance_id: instance_id)
    callable ||= FactoryCallable.new
    coordinator ||= inventory::ProbeCoordinator.new(instance_key: key, enqueue: ->(**) { true })
    inventory::Registry.claim_instance(
      instance_key: key, callable: callable, probe_request_handle: coordinator
    )
  end

  # Mark an already-activated exact instance unavailable via the dispatch path.
  def mark_unavailable(provider_family:, instance_id:, publisher_token_id:, reason: 'test instance unavailable')
    key = instance_key(provider_family: provider_family, instance_id: instance_id)
    inventory::Registry.dispatch_instance_unavailable(
      instance_key: key, publisher_token_id: publisher_token_id, reason: reason
    )
  end

  def snapshot
    inventory::Registry.snapshot
  end

  # Convenience: reset the registry to a clean generation-zero store (RSpec-only).
  def reset!
    inventory::Registry.reset!
  end
end

RSpec.configure do |config|
  config.include SsotV3SnapshotFactory, ssot_v3: true
  config.before(ssot_v3: true) { Legion::Extensions::Llm::Inventory::Registry.reset! }
end
