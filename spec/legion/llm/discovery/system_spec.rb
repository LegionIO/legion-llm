# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/system'

RSpec.describe Legion::LLM::Discovery::System do
  before { described_class.reset! }

  describe '.platform' do
    it 'returns :macos, :linux, or :unknown' do
      expect(%i[macos linux unknown]).to include(described_class.platform)
    end
  end

  describe '.total_memory_mb' do
    context 'on macOS' do
      before do
        allow(described_class).to receive(:platform).and_return(:macos)
        allow(described_class).to receive(:`).with('sysctl -n hw.memsize').and_return("68719476736\n")
      end

      it 'returns total memory in MB' do
        described_class.refresh!
        expect(described_class.total_memory_mb).to eq(65_536)
      end
    end

    context 'on Linux' do
      before do
        allow(described_class).to receive(:platform).and_return(:linux)
        meminfo = "MemTotal:       65536000 kB\nMemFree:        32000000 kB\nInactive:        8000000 kB\n"
        allow(File).to receive(:read).with('/proc/meminfo').and_return(meminfo)
      end

      it 'returns total memory in MB' do
        described_class.refresh!
        expect(described_class.total_memory_mb).to eq(64_000)
      end
    end

    context 'on unknown platform' do
      before { allow(described_class).to receive(:platform).and_return(:unknown) }

      it 'returns nil' do
        described_class.refresh!
        expect(described_class.total_memory_mb).to be_nil
      end
    end
  end

  describe '.available_memory_mb' do
    context 'on macOS' do
      before do
        allow(described_class).to receive(:platform).and_return(:macos)
        allow(described_class).to receive(:`).with('sysctl -n hw.memsize').and_return("68719476736\n")
        vm_stat_output = <<~VMSTAT
          Mach Virtual Memory Statistics: (page size of 16384 bytes)
          Pages free:                              500000.
          Pages active:                            200000.
          Pages inactive:                          300000.
          Pages speculative:                        50000.
          Pages throttled:                              0.
          Pages wired down:                        100000.
          Pages purgeable:                          10000.
        VMSTAT
        allow(described_class).to receive(:`).with('vm_stat').and_return(vm_stat_output)
      end

      it 'returns free + inactive pages in MB (excludes disk cache)' do
        described_class.refresh!
        # (500000 + 300000) pages * 16384 bytes / 1024 / 1024 = 12500 MB
        expect(described_class.available_memory_mb).to eq(12_500)
      end
    end

    context 'on Linux' do
      before do
        allow(described_class).to receive(:platform).and_return(:linux)
        meminfo = "MemTotal:       65536000 kB\nMemFree:        32000000 kB\nInactive:        8000000 kB\n"
        allow(File).to receive(:read).with('/proc/meminfo').and_return(meminfo)
      end

      it 'returns MemFree + Inactive in MB' do
        described_class.refresh!
        # (32000000 + 8000000) kB / 1024 = 39062 MB
        expect(described_class.available_memory_mb).to eq(39_062)
      end
    end
  end

  describe '.memory_pressure?' do
    before do
      allow(described_class).to receive(:platform).and_return(:macos)
      allow(described_class).to receive(:`).with('sysctl -n hw.memsize').and_return("68719476736\n")
    end

    context 'when available memory is below floor' do
      before do
        vm_stat_output = <<~VMSTAT
          Mach Virtual Memory Statistics: (page size of 16384 bytes)
          Pages free:                               50000.
          Pages active:                            200000.
          Pages inactive:                           50000.
          Pages speculative:                            0.
        VMSTAT
        allow(described_class).to receive(:`).with('vm_stat').and_return(vm_stat_output)
      end

      it 'returns true' do
        described_class.refresh!
        # (50000 + 50000) * 16384 / 1024 / 1024 = 1562 MB < 2048 default floor
        expect(described_class.memory_pressure?).to be true
      end
    end

    context 'when available memory is above floor' do
      before do
        vm_stat_output = <<~VMSTAT
          Mach Virtual Memory Statistics: (page size of 16384 bytes)
          Pages free:                              500000.
          Pages active:                            200000.
          Pages inactive:                          300000.
          Pages speculative:                            0.
        VMSTAT
        allow(described_class).to receive(:`).with('vm_stat').and_return(vm_stat_output)
      end

      it 'returns false' do
        described_class.refresh!
        expect(described_class.memory_pressure?).to be false
      end
    end
  end

  describe '.stale?' do
    it 'returns true when never refreshed' do
      expect(described_class.stale?).to be true
    end

    it 'returns false immediately after refresh' do
      allow(described_class).to receive(:platform).and_return(:unknown)
      described_class.refresh!
      expect(described_class.stale?).to be false
    end
  end

  describe '.reset!' do
    it 'clears cached data' do
      allow(described_class).to receive(:platform).and_return(:unknown)
      described_class.refresh!
      described_class.reset!
      expect(described_class.stale?).to be true
    end
  end
end
