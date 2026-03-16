# Ollama Discovery & System Memory Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Ollama model discovery (`/api/tags`) and OS memory introspection to legion-llm so the router can skip rules targeting models that aren't pulled or that exceed available RAM.

**Architecture:** Two new modules (`Discovery::Ollama`, `Discovery::System`) provide lazy TTL-cached lookups. The Router's `select_candidates` pipeline gains one new filter step between constraint filtering and tier availability. Settings add a `discovery` key.

**Tech Stack:** Ruby, Faraday (transitive dep via ruby_llm), macOS `sysctl`/`vm_stat`, Linux `/proc/meminfo`, RSpec + WebMock

---

### Task 1: Add discovery settings defaults

**Files:**
- Modify: `lib/legion/llm/settings.rb:6-14`

**Step 1: Write the failing test**

Create `spec/legion/llm/discovery/settings_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Discovery settings defaults' do
  it 'includes discovery key in LLM settings' do
    expect(Legion::Settings[:llm][:discovery]).to be_a(Hash)
  end

  it 'defaults enabled to true' do
    expect(Legion::Settings[:llm][:discovery][:enabled]).to be true
  end

  it 'defaults refresh_seconds to 60' do
    expect(Legion::Settings[:llm][:discovery][:refresh_seconds]).to eq(60)
  end

  it 'defaults memory_floor_mb to 2048' do
    expect(Legion::Settings[:llm][:discovery][:memory_floor_mb]).to eq(2048)
  end
end
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec spec/legion/llm/discovery/settings_spec.rb -v`
Expected: FAIL — `discovery` key is nil

**Step 3: Write minimal implementation**

Edit `lib/legion/llm/settings.rb`. Add `discovery: discovery_defaults` to the `default` hash and add the `discovery_defaults` method:

```ruby
def self.default
  {
    enabled:          true,
    connected:        false,
    default_model:    nil,
    default_provider: nil,
    providers:        providers,
    routing:          routing_defaults,
    discovery:        discovery_defaults
  }
end

def self.discovery_defaults
  {
    enabled:         true,
    refresh_seconds: 60,
    memory_floor_mb: 2048
  }
end
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec spec/legion/llm/discovery/settings_spec.rb -v`
Expected: 4 examples, 0 failures

**Step 5: Run full suite to verify no regressions**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec`
Expected: All existing tests pass

**Step 6: Commit**

```bash
cd /Users/miverso2/rubymine/legion/legion-llm
git add lib/legion/llm/settings.rb spec/legion/llm/discovery/settings_spec.rb
git commit -m "add discovery settings defaults"
```

---

### Task 2: Implement Discovery::System

**Files:**
- Create: `lib/legion/llm/discovery/system.rb`
- Create: `spec/legion/llm/discovery/system_spec.rb`

**Step 1: Write the failing test**

Create `spec/legion/llm/discovery/system_spec.rb`:

```ruby
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
        # 64 GB in bytes
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
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec spec/legion/llm/discovery/system_spec.rb -v`
Expected: FAIL — file not found / constant not defined

**Step 3: Write minimal implementation**

Create `lib/legion/llm/discovery/system.rb`:

```ruby
# frozen_string_literal: true

module Legion
  module LLM
    module Discovery
      module System
        class << self
          def total_memory_mb
            ensure_fresh
            @total_memory_mb
          end

          def available_memory_mb
            ensure_fresh
            @available_memory_mb
          end

          def memory_pressure?
            avail = available_memory_mb
            return false if avail.nil?

            floor = discovery_settings[:memory_floor_mb] || 2048
            avail < floor
          end

          def platform
            @platform ||= detect_platform
          end

          def refresh!
            case platform
            when :macos then refresh_macos
            when :linux then refresh_linux
            else
              @total_memory_mb = nil
              @available_memory_mb = nil
            end
            @last_refreshed_at = Time.now
          end

          def reset!
            @total_memory_mb = nil
            @available_memory_mb = nil
            @last_refreshed_at = nil
            @platform = nil
          end

          def stale?
            return true if @last_refreshed_at.nil?

            ttl = discovery_settings[:refresh_seconds] || 60
            Time.now - @last_refreshed_at > ttl
          end

          private

          def ensure_fresh
            refresh! if stale?
          end

          def detect_platform
            case RbConfig::CONFIG['host_os']
            when /darwin/i then :macos
            when /linux/i  then :linux
            else :unknown
            end
          end

          def refresh_macos
            raw_total = `sysctl -n hw.memsize`.strip.to_i
            @total_memory_mb = raw_total / 1024 / 1024

            vm_output = `vm_stat`
            page_size = vm_output[/page size of (\d+) bytes/, 1]&.to_i || 16_384
            free     = vm_output[/Pages free:\s+(\d+)/, 1]&.to_i || 0
            inactive = vm_output[/Pages inactive:\s+(\d+)/, 1]&.to_i || 0

            @available_memory_mb = (free + inactive) * page_size / 1024 / 1024
          rescue StandardError
            @total_memory_mb = nil
            @available_memory_mb = nil
          end

          def refresh_linux
            meminfo = File.read('/proc/meminfo')
            total_kb    = meminfo[/MemTotal:\s+(\d+)/, 1]&.to_i || 0
            free_kb     = meminfo[/MemFree:\s+(\d+)/, 1]&.to_i || 0
            inactive_kb = meminfo[/Inactive:\s+(\d+)/, 1]&.to_i || 0

            @total_memory_mb = total_kb / 1024
            @available_memory_mb = (free_kb + inactive_kb) / 1024
          rescue StandardError
            @total_memory_mb = nil
            @available_memory_mb = nil
          end

          def discovery_settings
            return {} unless Legion.const_defined?('Settings')

            Legion::Settings[:llm][:discovery] || {}
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec spec/legion/llm/discovery/system_spec.rb -v`
Expected: All examples pass

**Step 5: Run full suite**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec`
Expected: All tests pass

**Step 6: Commit**

```bash
cd /Users/miverso2/rubymine/legion/legion-llm
git add lib/legion/llm/discovery/system.rb spec/legion/llm/discovery/system_spec.rb
git commit -m "add Discovery::System for OS memory introspection"
```

---

### Task 3: Implement Discovery::Ollama

**Files:**
- Create: `lib/legion/llm/discovery/ollama.rb`
- Create: `spec/legion/llm/discovery/ollama_spec.rb`

**Step 1: Write the failing test**

Create `spec/legion/llm/discovery/ollama_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/ollama'

RSpec.describe Legion::LLM::Discovery::Ollama do
  before { described_class.reset! }

  let(:tags_response) do
    {
      'models' => [
        { 'name' => 'llama3.1:8b',       'size' => 4_700_000_000, 'digest' => 'sha256:abc' },
        { 'name' => 'qwen2.5:32b',       'size' => 20_000_000_000, 'digest' => 'sha256:def' },
        { 'name' => 'nomic-embed-text',   'size' => 274_000_000,   'digest' => 'sha256:ghi' }
      ]
    }
  end

  before do
    stub_request(:get, 'http://localhost:11434/api/tags')
      .to_return(status: 200, body: tags_response.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  describe '.models' do
    it 'returns array of model hashes from Ollama' do
      expect(described_class.models).to be_an(Array)
      expect(described_class.models.size).to eq(3)
    end

    it 'includes model name and size' do
      model = described_class.models.first
      expect(model['name']).to eq('llama3.1:8b')
      expect(model['size']).to eq(4_700_000_000)
    end
  end

  describe '.model_names' do
    it 'returns array of model name strings' do
      expect(described_class.model_names).to eq(['llama3.1:8b', 'qwen2.5:32b', 'nomic-embed-text'])
    end
  end

  describe '.model_available?' do
    it 'returns true for a pulled model' do
      expect(described_class.model_available?('llama3.1:8b')).to be true
    end

    it 'returns false for a model not pulled' do
      expect(described_class.model_available?('nonexistent:latest')).to be false
    end
  end

  describe '.model_size' do
    it 'returns size in bytes for a known model' do
      expect(described_class.model_size('qwen2.5:32b')).to eq(20_000_000_000)
    end

    it 'returns nil for an unknown model' do
      expect(described_class.model_size('nonexistent:latest')).to be_nil
    end
  end

  describe 'when Ollama is not running' do
    before do
      described_class.reset!
      stub_request(:get, 'http://localhost:11434/api/tags').to_timeout
    end

    it 'returns empty array for models' do
      expect(described_class.models).to eq([])
    end

    it 'returns false for model_available?' do
      expect(described_class.model_available?('llama3.1:8b')).to be false
    end
  end

  describe 'when Ollama returns non-200' do
    before do
      described_class.reset!
      stub_request(:get, 'http://localhost:11434/api/tags').to_return(status: 500, body: 'error')
    end

    it 'returns empty array for models' do
      expect(described_class.models).to eq([])
    end
  end

  describe '.stale?' do
    it 'returns true when never refreshed' do
      expect(described_class.stale?).to be true
    end

    it 'returns false immediately after refresh' do
      described_class.refresh!
      expect(described_class.stale?).to be false
    end
  end

  describe '.reset!' do
    it 'clears cached models' do
      described_class.refresh!
      expect(described_class.models.size).to eq(3)
      described_class.reset!
      # After reset, next access triggers fresh fetch
      stub_request(:get, 'http://localhost:11434/api/tags')
        .to_return(status: 200, body: { 'models' => [] }.to_json)
      expect(described_class.models).to eq([])
    end
  end

  describe 'TTL-based staleness' do
    it 'uses refresh_seconds from settings' do
      Legion::Settings[:llm][:discovery] = { enabled: true, refresh_seconds: 10 }
      described_class.refresh!
      expect(described_class.stale?).to be false

      # Simulate time passing
      described_class.instance_variable_set(:@last_refreshed_at, Time.now - 11)
      expect(described_class.stale?).to be true
    end
  end

  describe 'custom base_url' do
    before do
      described_class.reset!
      Legion::Settings[:llm][:providers][:ollama][:base_url] = 'http://gpu-server:11434'
      stub_request(:get, 'http://gpu-server:11434/api/tags')
        .to_return(status: 200, body: tags_response.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'queries the configured base_url' do
      described_class.refresh!
      expect(described_class.model_names).to eq(['llama3.1:8b', 'qwen2.5:32b', 'nomic-embed-text'])
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec spec/legion/llm/discovery/ollama_spec.rb -v`
Expected: FAIL — constant not defined

**Step 3: Write minimal implementation**

Create `lib/legion/llm/discovery/ollama.rb`:

```ruby
# frozen_string_literal: true

require 'faraday'
require 'json'

module Legion
  module LLM
    module Discovery
      module Ollama
        class << self
          def models
            ensure_fresh
            @models || []
          end

          def model_names
            models.map { |m| m['name'] }
          end

          def model_available?(name)
            model_names.include?(name)
          end

          def model_size(name)
            models.find { |m| m['name'] == name }&.dig('size')
          end

          def refresh!
            response = connection.get('/api/tags')
            if response.success?
              parsed = ::JSON.parse(response.body)
              @models = parsed['models'] || []
            else
              @models = [] unless @models
            end
          rescue StandardError
            @models ||= []
          ensure
            @last_refreshed_at = Time.now
          end

          def reset!
            @models = nil
            @last_refreshed_at = nil
          end

          def stale?
            return true if @last_refreshed_at.nil?

            ttl = discovery_settings[:refresh_seconds] || 60
            Time.now - @last_refreshed_at > ttl
          end

          private

          def ensure_fresh
            refresh! if stale?
          end

          def connection
            base = ollama_base_url
            Faraday.new(url: base) do |f|
              f.options.timeout = 2
              f.options.open_timeout = 2
              f.adapter Faraday.default_adapter
            end
          end

          def ollama_base_url
            return 'http://localhost:11434' unless Legion.const_defined?('Settings')

            Legion::Settings[:llm].dig(:providers, :ollama, :base_url) || 'http://localhost:11434'
          rescue StandardError
            'http://localhost:11434'
          end

          def discovery_settings
            return {} unless Legion.const_defined?('Settings')

            Legion::Settings[:llm][:discovery] || {}
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec spec/legion/llm/discovery/ollama_spec.rb -v`
Expected: All examples pass

**Step 5: Run full suite**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec`
Expected: All tests pass

**Step 6: Commit**

```bash
cd /Users/miverso2/rubymine/legion/legion-llm
git add lib/legion/llm/discovery/ollama.rb spec/legion/llm/discovery/ollama_spec.rb
git commit -m "add Discovery::Ollama for model tag introspection"
```

---

### Task 4: Integrate discovery into Router.select_candidates

**Files:**
- Modify: `lib/legion/llm/router.rb:1-8` (add require) and `lib/legion/llm/router.rb:88-105` (add filter step)
- Create: `spec/legion/llm/discovery/router_integration_spec.rb`

**Step 1: Write the failing test**

Create `spec/legion/llm/discovery/router_integration_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/ollama'
require 'legion/llm/discovery/system'

RSpec.describe 'Router discovery integration' do
  let(:rules_with_local) do
    [
      {
        name: 'local-small',
        when: { capability: 'basic' },
        then: { tier: 'local', provider: 'ollama', model: 'llama3.1:8b' },
        priority: 80,
        cost_multiplier: 0.1
      },
      {
        name: 'cloud-fallback',
        when: { capability: 'basic' },
        then: { tier: 'cloud', provider: 'bedrock', model: 'claude-sonnet-4-6' },
        priority: 20,
        cost_multiplier: 1.0
      }
    ]
  end

  before do
    Legion::LLM::Router.reset!
    Legion::LLM::Discovery::Ollama.reset!
    Legion::LLM::Discovery::System.reset!
    allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
  end

  def configure_routing(rules:)
    Legion::Settings[:llm] = Legion::Settings[:llm].merge(
      routing: {
        enabled: true,
        rules: rules,
        default_intent: { privacy: 'normal', capability: 'basic' }
      },
      discovery: { enabled: true, refresh_seconds: 60, memory_floor_mb: 2048 }
    )
  end

  describe 'when Ollama model is not pulled' do
    before do
      configure_routing(rules: rules_with_local)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).with('llama3.1:8b').and_return(false)
      allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(32_000)
    end

    it 'skips the local rule and falls through to cloud' do
      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.rule).to eq('cloud-fallback')
      expect(result.tier).to eq(:cloud)
    end
  end

  describe 'when Ollama model is pulled and fits in memory' do
    before do
      configure_routing(rules: rules_with_local)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).with('llama3.1:8b').and_return(true)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).with('llama3.1:8b').and_return(4_700_000_000)
      allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(32_000)
    end

    it 'selects the local rule' do
      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.rule).to eq('local-small')
      expect(result.tier).to eq(:local)
    end
  end

  describe 'when model is pulled but does not fit in memory' do
    before do
      configure_routing(rules: rules_with_local)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).with('llama3.1:8b').and_return(true)
      # Model is 4.7 GB, but only 3 GB available after floor
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).with('llama3.1:8b').and_return(4_700_000_000)
      allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(5_000)
    end

    it 'skips the local rule (insufficient memory after floor)' do
      # 5000 MB available - 2048 MB floor = 2952 MB usable, model needs ~4482 MB
      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.rule).to eq('cloud-fallback')
    end
  end

  describe 'when discovery is disabled' do
    before do
      Legion::Settings[:llm] = Legion::Settings[:llm].merge(
        routing: {
          enabled: true,
          rules: rules_with_local,
          default_intent: { privacy: 'normal', capability: 'basic' }
        },
        discovery: { enabled: false }
      )
    end

    it 'does not filter by discovery — local rule passes through' do
      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.rule).to eq('local-small')
    end
  end

  describe 'when system memory is nil (unknown platform)' do
    before do
      configure_routing(rules: rules_with_local)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).with('llama3.1:8b').and_return(true)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).with('llama3.1:8b').and_return(4_700_000_000)
      allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(nil)
    end

    it 'bypasses memory check (permissive) and selects local rule' do
      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.rule).to eq('local-small')
    end
  end

  describe 'non-Ollama rules are unaffected' do
    let(:cloud_only_rules) do
      [
        {
          name: 'cloud-reasoning',
          when: { capability: 'reasoning' },
          then: { tier: 'cloud', provider: 'bedrock', model: 'claude-sonnet-4-6' },
          priority: 50,
          cost_multiplier: 1.0
        }
      ]
    end

    before { configure_routing(rules: cloud_only_rules) }

    it 'does not check discovery for cloud rules' do
      expect(Legion::LLM::Discovery::Ollama).not_to receive(:model_available?)
      Legion::LLM::Router.resolve(intent: { capability: 'reasoning' })
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec spec/legion/llm/discovery/router_integration_spec.rb -v`
Expected: FAIL — discovery filtering not implemented

**Step 3: Write minimal implementation**

Edit `lib/legion/llm/router.rb`:

At the top, add requires after the existing ones (line 4):

```ruby
require_relative 'discovery/ollama'
require_relative 'discovery/system'
```

In `select_candidates` method (currently lines 88-105), add step 4.5 between step 4 and step 5. Replace the method with:

```ruby
def select_candidates(rules, intent)
  # 1. Collect constraints from constraint rules that match the intent
  constraints = rules
                .select { |r| r.constraint && r.matches_intent?(intent) }
                .map(&:constraint)

  # 2. Filter by intent match
  matched = rules.select { |r| r.matches_intent?(intent) }

  # 3. Filter by schedule
  scheduled = matched.select(&:within_schedule?)

  # 4. Reject rules excluded by active constraints
  unconstrained = scheduled.reject { |r| excluded_by_constraint?(r, constraints) }

  # 4.5 Reject Ollama rules where model is not pulled or doesn't fit
  discovered = unconstrained.reject { |r| excluded_by_discovery?(r) }

  # 5. Filter by tier availability
  discovered.select { |r| tier_available?(r.target[:tier] || r.target['tier']) }
end
```

Add the new private method `excluded_by_discovery?`:

```ruby
def excluded_by_discovery?(rule)
  return false unless discovery_enabled?

  tier     = (rule.target[:tier] || rule.target['tier'])&.to_sym
  provider = (rule.target[:provider] || rule.target['provider'])&.to_sym
  model    = rule.target[:model] || rule.target['model']

  return false unless tier == :local && provider == :ollama && model

  return true unless Discovery::Ollama.model_available?(model)

  model_bytes = Discovery::Ollama.model_size(model)
  available   = Discovery::System.available_memory_mb
  return false if model_bytes.nil? || available.nil?

  floor = discovery_settings[:memory_floor_mb] || 2048
  model_mb = model_bytes / 1024 / 1024
  model_mb > (available - floor)
end

def discovery_enabled?
  ds = discovery_settings
  ds.fetch(:enabled, true)
end

def discovery_settings
  llm = Legion::Settings[:llm]
  return {} unless llm.is_a?(Hash)

  (llm[:discovery] || {}).transform_keys(&:to_sym)
rescue StandardError
  {}
end
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec spec/legion/llm/discovery/router_integration_spec.rb -v`
Expected: All examples pass

**Step 5: Run full suite**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec`
Expected: All tests pass (existing router_spec stubs `tier_available?` but doesn't stub discovery — discovery checks should pass through because the rules in existing tests won't trigger the Ollama check when discovery module returns empty models, causing `model_available?` to return false. **Important:** The existing `router_spec.rb` stubs `tier_available?` but the new discovery filter will now reject local Ollama rules unless we also handle this. Existing specs use `allow(described_class).to receive(:tier_available?).and_return(true)` — we need to also stub discovery for existing specs. Add to `router_spec.rb` `before` block: `allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).and_return(true)` and `allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(65_536)`)

**Step 6: Fix existing router_spec.rb**

Edit `spec/legion/llm/router_spec.rb` — add to the existing `before` block (line 46-49):

```ruby
before do
  described_class.reset!
  allow(described_class).to receive(:tier_available?).and_return(true)
  allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).and_return(true)
  allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(65_536)
end
```

**Step 7: Run full suite again**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec`
Expected: All tests pass

**Step 8: Commit**

```bash
cd /Users/miverso2/rubymine/legion/legion-llm
git add lib/legion/llm/router.rb lib/legion/llm/discovery/ollama.rb lib/legion/llm/discovery/system.rb \
        spec/legion/llm/discovery/router_integration_spec.rb spec/legion/llm/router_spec.rb
git commit -m "integrate discovery filtering into router pipeline"
```

---

### Task 5: Add startup discovery logging

**Files:**
- Modify: `lib/legion/llm.rb:15-25` (add discovery warmup to `start`)

**Step 1: Write the failing test**

Add to `spec/legion/llm_spec.rb` (or create a focused spec — check existing file first to see the pattern, then add a new describe block). Create `spec/legion/llm/discovery/startup_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/ollama'
require 'legion/llm/discovery/system'

RSpec.describe 'LLM startup discovery' do
  before do
    Legion::LLM::Discovery::Ollama.reset!
    Legion::LLM::Discovery::System.reset!
    allow(RubyLLM).to receive(:configure)
    allow(RubyLLM).to receive(:chat).and_return(double(ask: 'pong'))
  end

  context 'when Ollama provider is enabled' do
    before do
      Legion::Settings[:llm][:providers][:ollama][:enabled] = true
      stub_request(:get, 'http://localhost:11434/api/tags')
        .to_return(status: 200, body: { 'models' => [{ 'name' => 'llama3:latest', 'size' => 4_000_000_000 }] }.to_json)
      allow(Legion::LLM::Discovery::System).to receive(:platform).and_return(:macos)
      allow(Legion::LLM::Discovery::System).to receive(:`).with('sysctl -n hw.memsize').and_return("68719476736\n")
      allow(Legion::LLM::Discovery::System).to receive(:`).with('vm_stat').and_return(
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:     500000.\nPages inactive:  300000.\n"
      )
    end

    it 'refreshes discovery caches during start' do
      expect(Legion::LLM::Discovery::Ollama).to receive(:refresh!)
      expect(Legion::LLM::Discovery::System).to receive(:refresh!)
      Legion::LLM.start
    end

    it 'logs discovered models' do
      expect(Legion::Logging).to receive(:info).with(/Ollama: 1 model/).at_least(:once)
      Legion::LLM.start
    end
  end

  context 'when Ollama provider is disabled' do
    before do
      Legion::Settings[:llm][:providers][:ollama][:enabled] = false
    end

    it 'does not refresh discovery caches' do
      expect(Legion::LLM::Discovery::Ollama).not_to receive(:refresh!)
      Legion::LLM.start
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec spec/legion/llm/discovery/startup_spec.rb -v`
Expected: FAIL — `refresh!` not called during start

**Step 3: Write minimal implementation**

Edit `lib/legion/llm.rb`. Add require at top (after line 8):

```ruby
require 'legion/llm/discovery/ollama'
require 'legion/llm/discovery/system'
```

Modify the `start` method to call discovery between `configure_providers` and `set_defaults`:

```ruby
def start
  Legion::Logging.debug 'Legion::LLM is running start'

  configure_providers
  run_discovery
  set_defaults

  @started = true
  Legion::Settings[:llm][:connected] = true
  Legion::Logging.info 'Legion::LLM started'
  ping_provider
end
```

Add the private method:

```ruby
def run_discovery
  return unless settings.dig(:providers, :ollama, :enabled)

  Discovery::Ollama.refresh!
  Discovery::System.refresh!

  names = Discovery::Ollama.model_names
  count = names.size
  Legion::Logging.info "Ollama: #{count} model#{'s' unless count == 1} available (#{names.join(', ')})"
  Legion::Logging.info "System: #{Discovery::System.total_memory_mb} MB total, " \
                       "#{Discovery::System.available_memory_mb} MB available"
rescue StandardError => e
  Legion::Logging.warn "Discovery failed: #{e.message}"
end
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec spec/legion/llm/discovery/startup_spec.rb -v`
Expected: All examples pass

**Step 5: Run full suite**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec`
Expected: All tests pass

**Step 6: Commit**

```bash
cd /Users/miverso2/rubymine/legion/legion-llm
git add lib/legion/llm.rb spec/legion/llm/discovery/startup_spec.rb
git commit -m "add discovery warmup and logging to LLM startup"
```

---

### Task 6: Run RuboCop, bump version, update docs

**Files:**
- Modify: `lib/legion/llm/version.rb` (bump 0.2.1 -> 0.2.2)
- Modify: `CHANGELOG.md`

**Step 1: Run RuboCop**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rubocop`
Expected: 0 offenses (fix any that appear)

**Step 2: Bump version**

Edit `lib/legion/llm/version.rb`:

```ruby
VERSION = '0.2.2'
```

**Step 3: Update CHANGELOG.md**

Add under `## [Unreleased]`:

```markdown
## [0.2.2]

### Added
- `Legion::LLM::Discovery::Ollama` module — queries Ollama `/api/tags` for pulled models with TTL cache
- `Legion::LLM::Discovery::System` module — queries OS memory (macOS `vm_stat`/`sysctl`, Linux `/proc/meminfo`) with TTL cache
- Router step 4.5: rejects Ollama rules where model is not pulled or exceeds available memory
- Discovery settings: `enabled`, `refresh_seconds`, `memory_floor_mb` under `Legion::Settings[:llm][:discovery]`
- Startup discovery: logs available Ollama models and system memory when Ollama provider is enabled
```

**Step 4: Run full suite one final time**

Run: `cd /Users/miverso2/rubymine/legion/legion-llm && bundle exec rspec && bundle exec rubocop`
Expected: All tests pass, 0 offenses

**Step 5: Update CLAUDE.md**

Add the new files to the File Map table in `CLAUDE.md`:

```
| `lib/legion/llm/discovery/ollama.rb` | Ollama /api/tags discovery with TTL cache |
| `lib/legion/llm/discovery/system.rb` | OS memory introspection (macOS + Linux) with TTL cache |
| `spec/legion/llm/discovery/ollama_spec.rb` | Tests: Ollama model discovery |
| `spec/legion/llm/discovery/system_spec.rb` | Tests: System memory introspection |
| `spec/legion/llm/discovery/router_integration_spec.rb` | Tests: Router discovery filtering |
| `spec/legion/llm/discovery/startup_spec.rb` | Tests: Startup discovery warmup |
| `spec/legion/llm/discovery/settings_spec.rb` | Tests: Discovery settings defaults |
```

Update the Module Structure diagram to include Discovery.

**Step 6: Commit**

```bash
cd /Users/miverso2/rubymine/legion/legion-llm
git add lib/legion/llm/version.rb CHANGELOG.md CLAUDE.md
git commit -m "bump to 0.2.2, update changelog and docs for discovery feature"
```
