# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/identity'

# G22 / opus C2 — pending P1 commit 5
# SSOT v3: Inventory.write_lane + Legion::LLM::InvalidLane are deleted — the
# 5-part lane-id invariant is owned by the lex-llm Identity composer/validator
# (the one place lane ids are composed, G22, and the one shape validator).
RSpec.describe Legion::Extensions::Llm::Inventory::Identity, 'lane id format validation (P1)' do
  it 'rejects malformed (non-5-part) lane ids' do
    expect do
      described_class.validate_lane_id!(value: 'vllm:apollo:gemma-12b')
    end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError, /5 parts/)
  end

  it 'rejects a missing lane id' do
    expect do
      described_class.parse_lane_id(nil)
    end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError, /String or Symbol/)
  end
end
