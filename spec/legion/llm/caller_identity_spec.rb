# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/caller_identity'

RSpec.describe Legion::LLM::CallerIdentity do
  describe '.normalize' do
    it 'returns a trackable unknown identity when no caller context is available' do
      expect(described_class.normalize).to eq(identity: 'unknown:anonymous', type: 'unknown')
    end

    it 'does not collapse generic system identity into an unqualified value' do
      expect(described_class.normalize(caller: { requested_by: { identity: 'system', type: 'service' } }))
        .to include(identity: 'service:system', type: 'service')
    end
  end
end
