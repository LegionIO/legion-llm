# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/skills'

RSpec.describe Legion::LLM::Skills do
  before { Legion::LLM::Skills::Registry.reset! }

  describe '.start' do
    it 'calls DiskLoader with configured + discovered directories' do
      allow(Legion::LLM::Skills::ExternalDiscovery).to receive(:discover).and_return(['/extra/dir'])
      allow(Legion::LLM).to receive(:settings)
        .and_return({ skills: { directories: ['.legion/skills'] } })
      expect(Legion::LLM::Skills::DiskLoader).to receive(:load_from_directories)
        .with(['.legion/skills', '/extra/dir'])
      described_class.start
    end

    it 'calls DiskLoader with only discovered directories when settings has none' do
      allow(Legion::LLM::Skills::ExternalDiscovery).to receive(:discover).and_return(['/auto/dir'])
      allow(Legion::LLM).to receive(:settings).and_return({ skills: { directories: [] } })
      expect(Legion::LLM::Skills::DiskLoader).to receive(:load_from_directories)
        .with(['/auto/dir'])
      described_class.start
    end
  end
end
