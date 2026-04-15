# Sticky Runner Tool Injection + Tool Call History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep deferred tool runners injected across multiple turns after trigger/execution, and surface a tool call history block in the system prompt so the LLM can reference prior tool results.

**Architecture:** Three new pipeline step modules (`Steps::StickyRunners`, `Steps::ToolHistory`, `Steps::StickyPersist`) wired into the Executor. State is stored in a dedicated `sticky_state` slot on each ConversationStore entry. LegionIO gains a `sticky` attribute on tool classes and a `sticky_tools?` opt-out on extensions.

**Tech Stack:** Ruby 3.4+, concurrent-ruby (`Concurrent::Array`), legion-llm pipeline, LegionIO Tools::Base/Discovery/Extensions::Core, RSpec

**Spec:** `docs/superpowers/specs/2026-04-15-sticky-runners-tool-history-design.md`

---

## File Map

**legion-llm** (create):
- `lib/legion/llm/pipeline/steps/sticky_runners.rb` — `Steps::StickyRunners` module with `step_sticky_runners`
- `lib/legion/llm/pipeline/steps/tool_history.rb` — `Steps::ToolHistory` module with `step_tool_history_inject`, `format_history`, `summarize_result`
- `lib/legion/llm/pipeline/steps/sticky_persist.rb` — `Steps::StickyPersist` module with `step_sticky_persist`, `sanitize_args`, `truncate_args`, settings helpers
- `spec/legion/llm/pipeline/steps/sticky_runners_spec.rb`
- `spec/legion/llm/pipeline/steps/tool_history_spec.rb`
- `spec/legion/llm/pipeline/steps/sticky_persist_spec.rb`

**legion-llm** (modify):
- `lib/legion/llm/conversation_store.rb` — add `read_sticky_state`, `write_sticky_state`, eviction warning
- `lib/legion/llm/pipeline/enrichment_injector.rb` — inject `tool:call_history` before empty guard
- `lib/legion/llm/pipeline/executor.rb` — new ivars, include new modules, update step arrays, update inject loops, update emit callbacks, update step_tool_calls
- `lib/legion/llm/pipeline/profile.rb` — add new steps to 4 skip lists
- `spec/legion/llm/conversation_store_spec.rb` — new sticky state tests
- `spec/legion/llm/pipeline/enrichment_injector_spec.rb` — history injection tests
- `spec/legion/llm/pipeline/executor_spec.rb` — new ivar and callback tests

**LegionIO** (modify):
- `lib/legion/tools/base.rb` — add `sticky` accessor
- `lib/legion/tools/discovery.rb` — add `sticky:` to `tool_attributes`, call `sticky(attrs[:sticky])` in `create_tool_class`
- `lib/legion/extensions/core.rb` — add `sticky_tools?` method
- `spec/legion/tools/base_spec.rb` — sticky accessor tests
- `spec/legion/tools/discovery_spec.rb` — sticky attribute tests
- `spec/legion/extensions/core_spec.rb` — sticky_tools? test

---

## Task 1: LegionIO — `sticky` accessor on `Tools::Base`

**Files:**
- Modify: `/Users/matt.iverson@optum.com/rubymine/legion/LegionIO/lib/legion/tools/base.rb`
- Test: `/Users/matt.iverson@optum.com/rubymine/legion/LegionIO/spec/legion/tools/base_spec.rb`

- [ ] **Step 1: Write failing tests**

Add to `spec/legion/tools/base_spec.rb`:

```ruby
RSpec.describe Legion::Tools::Base do
  describe '.sticky' do
    let(:tool_class) { Class.new(described_class) }

    it 'defaults to true when never set' do
      expect(tool_class.sticky).to eq(true)
    end

    it 'returns false when set to false' do
      tool_class.sticky(false)
      expect(tool_class.sticky).to eq(false)
    end

    it 'returns true when set to true' do
      tool_class.sticky(true)
      expect(tool_class.sticky).to eq(true)
    end

    it 'is a no-op read when called with nil' do
      tool_class.sticky(false)
      tool_class.sticky(nil)  # should NOT reset to true
      expect(tool_class.sticky).to eq(false)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
bundle exec rspec spec/legion/tools/base_spec.rb --format documentation 2>&1 | tail -15
```

Expected: failures mentioning `undefined method 'sticky'`

- [ ] **Step 3: Add `sticky` accessor to `Tools::Base`**

In `lib/legion/tools/base.rb`, add after the `trigger_words` accessor:

```ruby
def sticky(val = nil)
  return @sticky.nil? ? true : @sticky if val.nil?
  @sticky = val
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
bundle exec rspec spec/legion/tools/base_spec.rb --format documentation 2>&1 | tail -10
```

Expected: all sticky tests pass

- [ ] **Step 5: Run full suite to check for regressions**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
bundle exec rspec --format progress 2>&1 | tail -5
```

Expected: same failure count as baseline (6 pre-existing failures)

- [ ] **Step 6: Commit**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
git add lib/legion/tools/base.rb spec/legion/tools/base_spec.rb
git commit -m "add sticky accessor to Tools::Base — defaults true, supports false opt-out"
```

---

## Task 2: LegionIO — `sticky_tools?` on `Extensions::Core`

**Files:**
- Modify: `/Users/matt.iverson@optum.com/rubymine/legion/LegionIO/lib/legion/extensions/core.rb`
- Test: `/Users/matt.iverson@optum.com/rubymine/legion/LegionIO/spec/legion/extensions/core_spec.rb`

- [ ] **Step 1: Write failing test**

Add to `spec/legion/extensions/core_spec.rb` (inside the existing `RSpec.describe Legion::Extensions::Core`):

```ruby
describe '.sticky_tools?' do
  it 'returns true by default' do
    stub_const('Legion::Extensions::StickyTest', Module.new { extend Legion::Extensions::Core })
    expect(Legion::Extensions::StickyTest.sticky_tools?).to eq(true)
  end

  it 'can be overridden to false on extension module' do
    mod = Module.new do
      extend Legion::Extensions::Core
      def self.sticky_tools?
        false
      end
    end
    expect(mod.sticky_tools?).to eq(false)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
bundle exec rspec spec/legion/extensions/core_spec.rb --format documentation 2>&1 | tail -10
```

- [ ] **Step 3: Add `sticky_tools?` to `Extensions::Core`**

In `lib/legion/extensions/core.rb`, add after `mcp_tools_deferred?`:

```ruby
def sticky_tools?
  true
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
bundle exec rspec spec/legion/extensions/core_spec.rb --format documentation 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
git add lib/legion/extensions/core.rb spec/legion/extensions/core_spec.rb
git commit -m "add sticky_tools? to Extensions::Core — defaults true, extensions may override"
```

---

## Task 3: LegionIO — `sticky` attribute in `Tools::Discovery`

**Files:**
- Modify: `/Users/matt.iverson@optum.com/rubymine/legion/LegionIO/lib/legion/tools/discovery.rb`
- Test: `/Users/matt.iverson@optum.com/rubymine/legion/LegionIO/spec/legion/tools/discovery_spec.rb`

- [ ] **Step 1: Write failing tests**

Add to `spec/legion/tools/discovery_spec.rb`:

```ruby
describe 'sticky attribute on discovered tool classes' do
  let(:ext) do
    mod = Module.new
    mod.extend(Legion::Extensions::Core) if Legion::Extensions.const_defined?(:Core, false)
    mod
  end

  it 'sets sticky true when extension returns true from sticky_tools?' do
    allow(ext).to receive(:sticky_tools?).and_return(true)
    # use existing discovery helper or build tool_attributes directly
    attrs = Legion::Tools::Discovery.send(:tool_attributes, ext, double(name: 'Ext::Runners::Test'),
                                          :do_thing, { desc: 'test', options: {} }, nil, false)
    expect(attrs[:sticky]).to eq(true)
  end

  it 'sets sticky false when extension returns false' do
    allow(ext).to receive(:sticky_tools?).and_return(false)
    attrs = Legion::Tools::Discovery.send(:tool_attributes, ext, double(name: 'Ext::Runners::Test'),
                                          :do_thing, { desc: 'test', options: {} }, nil, false)
    expect(attrs[:sticky]).to eq(false)
  end

  it 'treats nil return from sticky_tools? as false (conservative opt-out)' do
    allow(ext).to receive(:sticky_tools?).and_return(nil)
    attrs = Legion::Tools::Discovery.send(:tool_attributes, ext, double(name: 'Ext::Runners::Test'),
                                          :do_thing, { desc: 'test', options: {} }, nil, false)
    expect(attrs[:sticky]).to eq(false)
  end

  it 'calls sticky() on the created tool class' do
    allow(ext).to receive(:sticky_tools?).and_return(false)
    tool_class = Legion::Tools::Discovery.send(:build_tool_class,
                   ext: ext,
                   runner_mod: double(name: 'Ext::Runners::Test', respond_to?: false),
                   func_name: :do_thing,
                   meta: { desc: 'test', options: {} },
                   defn: nil,
                   deferred: false)
    expect(tool_class.sticky).to eq(false)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
bundle exec rspec spec/legion/tools/discovery_spec.rb --format documentation 2>&1 | tail -15
```

- [ ] **Step 3: Add `sticky:` to `tool_attributes` and `sticky()` call in `create_tool_class`**

In `lib/legion/tools/discovery.rb`, inside `tool_attributes`, add `sticky:` to the hash:

```ruby
def tool_attributes(ext, runner_mod, func_name, meta, defn, deferred) # rubocop:disable Metrics/ParameterLists
  ext_name = derive_extension_name(ext)
  runner_snake = derive_runner_snake(runner_mod)
  {
    tool_name:     defn&.dig(:mcp_prefix) || "legion-#{ext_name}-#{runner_snake}-#{func_name}",
    description:   meta[:desc] || defn&.dig(:desc) || "#{ext_name}##{func_name}",
    input_schema:  normalize_schema(defn&.dig(:inputs)&.any? ? defn[:inputs] : meta[:options]),
    mcp_category:  defn&.dig(:mcp_category),
    mcp_tier:      defn&.dig(:mcp_tier),
    deferred:      deferred,
    ext_name:      ext_name,
    runner_snake:  runner_snake,
    trigger_words: merge_trigger_words(ext, runner_mod),
    sticky:        !!(ext.respond_to?(:sticky_tools?) ? ext.sticky_tools? : true)
  }
end
```

In `create_tool_class`, add `sticky(attrs[:sticky])` after `trigger_words(attrs[:trigger_words])`:

```ruby
trigger_words(attrs[:trigger_words])
sticky(attrs[:sticky])
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
bundle exec rspec spec/legion/tools/discovery_spec.rb --format documentation 2>&1 | tail -15
```

- [ ] **Step 5: Run full suite**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
bundle exec rspec --format progress 2>&1 | tail -5
bundle exec rubocop lib/legion/tools/discovery.rb 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
git add lib/legion/tools/discovery.rb spec/legion/tools/discovery_spec.rb
git commit -m "propagate sticky_tools? through Tools::Discovery to tool class sticky attribute"
```

---

## Task 4: ConversationStore — `read_sticky_state` / `write_sticky_state`

**Files:**
- Modify: `lib/legion/llm/conversation_store.rb`
- Test: `spec/legion/llm/conversation_store_spec.rb`

- [ ] **Step 1: Write failing tests**

Add to `spec/legion/llm/conversation_store_spec.rb`:

```ruby
describe '.read_sticky_state' do
  it 'returns a frozen empty hash when conversation is not in memory' do
    result = described_class.read_sticky_state('nonexistent-conv')
    expect(result).to eq({})
    expect(result).to be_frozen
  end

  it 'returns {} when conversation exists but has no sticky_state' do
    described_class.append('conv-1', role: :user, content: 'hello')
    result = described_class.read_sticky_state('conv-1')
    expect(result).to eq({})
  end

  it 'returns the stored sticky_state for an in-memory conversation' do
    described_class.append('conv-2', role: :user, content: 'hello')
    described_class.write_sticky_state('conv-2', { deferred_tool_calls: 3 })
    result = described_class.read_sticky_state('conv-2')
    expect(result[:deferred_tool_calls]).to eq(3)
  end
end

describe '.write_sticky_state' do
  it 'no-ops when conversation is not in memory' do
    expect { described_class.write_sticky_state('ghost', { foo: 1 }) }.not_to raise_error
    expect(described_class.read_sticky_state('ghost')).to eq({})
  end

  it 'persists state to an in-memory conversation' do
    described_class.append('conv-3', role: :user, content: 'hi')
    described_class.write_sticky_state('conv-3', { deferred_tool_calls: 7 })
    expect(described_class.read_sticky_state('conv-3')[:deferred_tool_calls]).to eq(7)
  end

  it 'replaces the entire sticky_state slot (not a merge)' do
    described_class.append('conv-4', role: :user, content: 'hi')
    described_class.write_sticky_state('conv-4', { a: 1, b: 2 })
    described_class.write_sticky_state('conv-4', { c: 3 })
    result = described_class.read_sticky_state('conv-4')
    expect(result).to eq({ c: 3 })
    expect(result[:a]).to be_nil
  end

  it 'updates the LRU tick via touch' do
    described_class.append('conv-5', role: :user, content: 'hi')
    tick_before = described_class.send(:conversations)['conv-5'][:lru_tick]
    described_class.write_sticky_state('conv-5', { x: 1 })
    tick_after = described_class.send(:conversations)['conv-5'][:lru_tick]
    expect(tick_after).to be > tick_before
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec spec/legion/llm/conversation_store_spec.rb -e "read_sticky_state\|write_sticky_state" --format documentation 2>&1 | tail -15
```

- [ ] **Step 3: Add methods to ConversationStore**

In `lib/legion/llm/conversation_store.rb`, add after `read_metadata`:

```ruby
def read_sticky_state(conversation_id)
  return {}.freeze unless in_memory?(conversation_id)
  conversations[conversation_id][:sticky_state] ||= {}
end

def write_sticky_state(conversation_id, state)
  return unless in_memory?(conversation_id)
  conversations[conversation_id][:sticky_state] = state
  touch(conversation_id)
end
```

In `evict_if_needed`, add a warning before `conversations.delete(oldest_id)`:

```ruby
if conversations[oldest_id]&.dig(:sticky_state)&.any?
  log&.warn("[ConversationStore] evicting #{oldest_id} with non-empty sticky_state — sticky state lost")
end
conversations.delete(oldest_id)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec spec/legion/llm/conversation_store_spec.rb --format documentation 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
git add lib/legion/llm/conversation_store.rb spec/legion/llm/conversation_store_spec.rb
git commit -m "add read_sticky_state/write_sticky_state to ConversationStore with LRU eviction warning"
```

---

## Task 5: `Steps::StickyRunners` — step file

**Files:**
- Create: `lib/legion/llm/pipeline/steps/sticky_runners.rb`
- Test: `spec/legion/llm/pipeline/steps/sticky_runners_spec.rb`

- [ ] **Step 1: Write failing tests**

Create `spec/legion/llm/pipeline/steps/sticky_runners_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'set'

RSpec.describe Legion::LLM::Pipeline::Steps::StickyRunners do
  let(:executor) do
    double(
      'executor',
      request:               double(conversation_id: 'conv-1'),
      triggered_tools:       [],
      enrichments:           {},
      timeline:              double(record: nil),
      warnings:              [],
      sticky_turn_snapshot:  nil,
      freshly_triggered_keys: []
    ).tap do |e|
      allow(e).to receive(:sticky_enabled?).and_return(true)
      allow(e).to receive(:handle_exception)
    end
  end

  # Build a minimal Executor subclass that includes the module
  let(:klass) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::StickyRunners

      attr_accessor :request, :triggered_tools, :enrichments, :sticky_turn_snapshot,
                    :freshly_triggered_keys, :warnings

      def initialize
        @triggered_tools        = []
        @enrichments            = {}
        @sticky_turn_snapshot   = nil
        @freshly_triggered_keys = []
        @warnings               = []
      end

      def timeline = @timeline ||= double(record: nil)
      def sticky_enabled? = true
      def handle_exception(e, **) = @warnings << e.message
    end
  end

  let(:instance) { klass.new }

  def fake_request(conv_id)
    double(conversation_id: conv_id)
  end

  describe '#step_sticky_runners' do
    before do
      allow(Legion::LLM::ConversationStore).to receive(:messages).and_return([
        { role: :user,      content: 'hello' },
        { role: :assistant, content: 'hi' },
        { role: :user,      content: 'for issues in github' }
      ])
      allow(Legion::LLM::ConversationStore).to receive(:read_sticky_state).and_return({})
      allow(Legion::Tools::Registry).to receive(:deferred_tools).and_return([])
    end

    it 'sets @sticky_turn_snapshot to count of user-role messages only' do
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_runners
      expect(instance.sticky_turn_snapshot).to eq(2)
    end

    it 'captures @freshly_triggered_keys BEFORE re-injection loop' do
      tool_a = double(tool_name: 'tool-a', extension: 'github', runner: 'issues', sticky: true)
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.triggered_tools << tool_a
      instance.step_sticky_runners
      expect(instance.freshly_triggered_keys).to eq(['github_issues'])
      # re-injected tools should NOT appear in freshly_triggered_keys
    end

    it 're-injects live execution-sticky runner tools into @triggered_tools' do
      tool_b = double(tool_name: 'tool-b', extension: 'github', runner: 'issues',
                      respond_to?: true, sticky: true)
      allow(Legion::Tools::Registry).to receive(:deferred_tools).and_return([tool_b])
      allow(Legion::LLM::ConversationStore).to receive(:read_sticky_state).and_return({
        sticky_runners: { 'github_issues' => { tier: :executed, expires_after_deferred_call: 10 } },
        deferred_tool_calls: 3
      })
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_runners
      expect(instance.triggered_tools).to include(tool_b)
    end

    it 'does NOT re-inject expired runners' do
      tool_c = double(tool_name: 'tool-c', extension: 'github', runner: 'issues',
                      respond_to?: true, sticky: true)
      allow(Legion::Tools::Registry).to receive(:deferred_tools).and_return([tool_c])
      allow(Legion::LLM::ConversationStore).to receive(:read_sticky_state).and_return({
        sticky_runners: { 'github_issues' => { tier: :executed, expires_after_deferred_call: 3 } },
        deferred_tool_calls: 5  # 5 >= 3 → expired
      })
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_runners
      expect(instance.triggered_tools).not_to include(tool_c)
    end

    it 'does NOT re-inject tools with sticky: false' do
      tool_d = double(tool_name: 'tool-d', extension: 'github', runner: 'issues',
                      respond_to?: true, sticky: false)
      allow(Legion::Tools::Registry).to receive(:deferred_tools).and_return([tool_d])
      allow(Legion::LLM::ConversationStore).to receive(:read_sticky_state).and_return({
        sticky_runners: { 'github_issues' => { tier: :executed, expires_after_deferred_call: 10 } },
        deferred_tool_calls: 3
      })
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_runners
      expect(instance.triggered_tools).not_to include(tool_d)
    end

    it 'returns early and does NOT set snapshot when conv_id is nil' do
      instance.instance_variable_set(:@request, fake_request(nil))
      instance.step_sticky_runners
      expect(instance.sticky_turn_snapshot).to be_nil
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec spec/legion/llm/pipeline/steps/sticky_runners_spec.rb --format documentation 2>&1 | tail -15
```

- [ ] **Step 3: Create `sticky_runners.rb`**

Create `lib/legion/llm/pipeline/steps/sticky_runners.rb`:

```ruby
# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module StickyRunners
          include Legion::Logging::Helper

          def step_sticky_runners
            return unless sticky_enabled? && @request.conversation_id

            conv_id = @request.conversation_id

            # MUST be first — before any modification to @triggered_tools
            @sticky_turn_snapshot = ConversationStore.messages(conv_id)
                                      .count { |m| (m[:role] || m['role']).to_s == 'user' }

            # MUST be second — captures trigger_match results before sticky re-injection
            @freshly_triggered_keys = @triggered_tools.map { |t| "#{t.extension}_#{t.runner}" }.uniq

            state          = ConversationStore.read_sticky_state(conv_id)
            runners        = state[:sticky_runners] || {}
            deferred_count = state[:deferred_tool_calls] || 0

            live_keys = runners.select do |_k, v|
              (v[:tier] == :triggered && @sticky_turn_snapshot < v[:expires_at_turn]) ||
              (v[:tier] == :executed  && deferred_count < v[:expires_after_deferred_call])
            end.keys

            if defined?(::Legion::Tools::Registry)
              ::Legion::Tools::Registry.deferred_tools.each do |tool_class|
                key = "#{tool_class.extension}_#{tool_class.runner}"
                next unless live_keys.include?(key)
                next if tool_class.respond_to?(:sticky) && tool_class.sticky == false
                next if @triggered_tools.any? { |t| t.tool_name == tool_class.tool_name }

                @triggered_tools << tool_class
              end
            end

            @enrichments['tool:sticky_runners'] = {
              content:   "#{live_keys.size} runners re-injected via stickiness",
              data:      { runner_keys: live_keys },
              timestamp: Time.now
            }
            @timeline.record(
              category: :enrichment, key: 'tool:sticky_runners',
              direction: :inbound, detail: "#{live_keys.size} sticky runners",
              from: 'sticky_state', to: 'pipeline'
            )
          rescue StandardError => e
            @warnings << "sticky_runners error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.step_sticky_runners')
          end

          private

          def sticky_enabled?
            Legion::Settings.dig(:llm, :tool_sticky, :enabled) != false
          end

          def trigger_sticky_turns
            Legion::Settings.dig(:llm, :tool_sticky, :trigger_turns) || 2
          end

          def execution_sticky_tool_calls
            Legion::Settings.dig(:llm, :tool_sticky, :execution_tool_calls) || 5
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec spec/legion/llm/pipeline/steps/sticky_runners_spec.rb --format documentation 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
git add lib/legion/llm/pipeline/steps/sticky_runners.rb spec/legion/llm/pipeline/steps/sticky_runners_spec.rb
git commit -m "add Steps::StickyRunners — re-injects live sticky runners into @triggered_tools"
```

---

## Task 6: `Steps::ToolHistory` — format and inject

**Files:**
- Create: `lib/legion/llm/pipeline/steps/tool_history.rb`
- Test: `spec/legion/llm/pipeline/steps/tool_history_spec.rb`

- [ ] **Step 1: Write failing tests**

Create `spec/legion/llm/pipeline/steps/tool_history_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::ToolHistory do
  let(:klass) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::ToolHistory

      attr_accessor :request, :enrichments, :warnings

      def initialize
        @enrichments = {}
        @warnings    = []
      end

      def sticky_enabled? = true
      def handle_exception(e, **) = @warnings << e.message
    end
  end

  let(:instance) { klass.new }

  def fake_request(conv_id)
    double(conversation_id: conv_id)
  end

  describe '#step_tool_history_inject' do
    it 'does nothing when history is empty' do
      allow(Legion::LLM::ConversationStore).to receive(:read_sticky_state).and_return({})
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_tool_history_inject
      expect(instance.enrichments['tool:call_history']).to be_nil
    end

    it 'sets enrichment with content/data/timestamp structure' do
      history = [{ tool: 'legion-github-issues-list_issues', runner: 'github_issues',
                   turn: 3, args: { owner: 'LegionIO' }, result: '{"result":[]}', error: false }]
      allow(Legion::LLM::ConversationStore).to receive(:read_sticky_state)
        .and_return({ tool_call_history: history })
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_tool_history_inject
      enrichment = instance.enrichments['tool:call_history']
      expect(enrichment[:content]).to include('Tools used in this conversation:')
      expect(enrichment[:data][:entry_count]).to eq(1)
      expect(enrichment[:timestamp]).to be_a(Time)
    end

    it 'returns early when conv_id is nil' do
      instance.instance_variable_set(:@request, fake_request(nil))
      instance.step_tool_history_inject
      expect(instance.enrichments['tool:call_history']).to be_nil
    end
  end

  describe '#summarize_result' do
    subject { instance }

    it 'returns error prefix when error is true' do
      expect(subject.send(:summarize_result, 'oops', true)).to start_with('error: oops')
    end

    it 'returns N items returned for array results' do
      json = Legion::JSON.dump([1, 2, 3])
      expect(subject.send(:summarize_result, json, false)).to eq('3 items returned')
    end

    it 'returns #N at URL for github-style results with number and html_url' do
      json = Legion::JSON.dump({ number: 42, html_url: 'https://github.com/foo/bar/issues/42' })
      expect(subject.send(:summarize_result, json, false)).to eq('#42 at https://github.com/foo/bar/issues/42')
    end

    it 'returns N items returned for nested result array' do
      json = Legion::JSON.dump({ result: [{ id: 1 }, { id: 2 }] })
      expect(subject.send(:summarize_result, json, false)).to eq('2 items returned')
    end

    it 'falls back to first 200 chars for unrecognized structures' do
      long_str = 'x' * 300
      expect(subject.send(:summarize_result, long_str, false).length).to eq(200)
    end

    it 'falls back gracefully on unparseable JSON' do
      expect(subject.send(:summarize_result, '{bad json', false)).to eq('{bad json'[0, 200])
    end
  end

  describe '#format_history_entry' do
    it 'formats args as key: value pairs with JSON for non-strings' do
      entry = { tool: 'my_tool', turn: 2,
                args: { owner: 'LegionIO', filters: { state: 'open' } },
                result: '[]', error: false }
      line = instance.send(:format_history_entry, entry)
      expect(line).to include('owner: LegionIO')
      expect(line).to include('"state":"open"')  # JSON not Ruby inspect
      expect(line).to start_with('- Turn 2:')
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec spec/legion/llm/pipeline/steps/tool_history_spec.rb --format documentation 2>&1 | tail -15
```

- [ ] **Step 3: Create `tool_history.rb`**

Create `lib/legion/llm/pipeline/steps/tool_history.rb`:

```ruby
# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module ToolHistory
          include Legion::Logging::Helper

          def step_tool_history_inject
            return unless sticky_enabled? && @request.conversation_id

            state   = ConversationStore.read_sticky_state(@request.conversation_id)
            history = state[:tool_call_history] || []
            return if history.empty?

            @enrichments['tool:call_history'] = {
              content:   format_history(history),
              data:      { entry_count: history.size },
              timestamp: Time.now
            }
          rescue StandardError => e
            @warnings << "tool_history_inject error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.step_tool_history_inject')
          end

          private

          def sticky_enabled?
            Legion::Settings.dig(:llm, :tool_sticky, :enabled) != false
          end

          def format_history(history)
            lines = history.map { |entry| format_history_entry(entry) }
            "Tools used in this conversation:\n#{lines.join("\n")}"
          end

          def format_history_entry(entry)
            args_str = (entry[:args] || {}).map do |k, v|
              val = v.is_a?(String) ? v : Legion::JSON.dump(v)
              "#{k}: #{val}"
            end.join(', ')
            summary = summarize_result(entry[:result], entry[:error])
            "- Turn #{entry[:turn]}: #{entry[:tool]}(#{args_str}) \u2192 #{summary}"
          end

          def summarize_result(result_str, error)
            return "error: #{result_str.to_s[0, 100]}" if error

            begin
              parsed = Legion::JSON.load(result_str.to_s)
            rescue StandardError
              return result_str.to_s[0, 200]
            end

            if parsed.is_a?(Array)
              "#{parsed.size} items returned"
            elsif parsed.is_a?(Hash)
              if parsed[:number] && parsed[:html_url]
                "##{parsed[:number]} at #{parsed[:html_url]}"
              elsif parsed[:result].is_a?(Array)
                "#{parsed[:result].size} items returned"
              elsif parsed[:result].is_a?(Hash) && parsed[:result][:number]
                "##{parsed[:result][:number]} at #{parsed[:result][:html_url]}"
              else
                result_str.to_s[0, 200]
              end
            else
              result_str.to_s[0, 200]
            end
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec spec/legion/llm/pipeline/steps/tool_history_spec.rb --format documentation 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
git add lib/legion/llm/pipeline/steps/tool_history.rb spec/legion/llm/pipeline/steps/tool_history_spec.rb
git commit -m "add Steps::ToolHistory — format_history, summarize_result, step_tool_history_inject"
```

---

## Task 7: `Steps::StickyPersist` — single persist step

**Files:**
- Create: `lib/legion/llm/pipeline/steps/sticky_persist.rb`
- Test: `spec/legion/llm/pipeline/steps/sticky_persist_spec.rb`

- [ ] **Step 1: Write failing tests**

Create `spec/legion/llm/pipeline/steps/sticky_persist_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::StickyPersist do
  let(:klass) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::StickyPersist

      attr_accessor :request, :pending_tool_history, :injected_tool_map,
                    :freshly_triggered_keys, :sticky_turn_snapshot, :warnings

      def initialize
        @pending_tool_history    = Concurrent::Array.new
        @injected_tool_map       = {}
        @freshly_triggered_keys  = []
        @sticky_turn_snapshot    = 3
        @warnings                = []
      end

      def sticky_enabled?             = true
      def handle_exception(e, **)     = @warnings << e.message
      def max_history_entries         = 50
      def max_result_length           = 2000
      def max_args_length             = 500
      def trigger_sticky_turns        = 2
      def execution_sticky_tool_calls = 5
    end
  end

  let(:instance) { klass.new }

  def fake_request(conv_id)
    double(conversation_id: conv_id)
  end

  def deferred_tool(name, ext, runner)
    double(tool_name: name, extension: ext, runner: runner, deferred?: true)
  end

  before do
    allow(Legion::LLM::ConversationStore).to receive(:read_sticky_state).and_return({})
    allow(Legion::LLM::ConversationStore).to receive(:write_sticky_state)
    allow(Legion::Tools::Registry).to receive(:all_tools).and_return([])
  end

  describe '#step_sticky_persist' do
    it 'returns early when sticky_turn_snapshot is nil (profile-skipped)' do
      instance.sticky_turn_snapshot = nil
      instance.instance_variable_set(:@request, fake_request('c1'))
      expect(Legion::LLM::ConversationStore).not_to receive(:write_sticky_state)
      instance.step_sticky_persist
    end

    it 'returns early when conv_id is nil' do
      instance.instance_variable_set(:@request, fake_request(nil))
      expect(Legion::LLM::ConversationStore).not_to receive(:write_sticky_state)
      instance.step_sticky_persist
    end

    it 'increments deferred_tool_calls by number of completed deferred tools' do
      tc = deferred_tool('legion-github-issues-list_issues', 'github', 'issues')
      instance.injected_tool_map['legion-github-issues-list_issues'] = tc
      instance.pending_tool_history << {
        tool_name: 'legion-github-issues-list_issues', result: '{}', error: false, runner_key: nil
      }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::ConversationStore).to have_received(:write_sticky_state) do |_, state|
        expect(state[:deferred_tool_calls]).to eq(1)
      end
    end

    it 'does NOT count errored tool calls toward deferred counter' do
      tc = deferred_tool('tool-err', 'github', 'issues')
      instance.injected_tool_map['tool-err'] = tc
      instance.pending_tool_history << {
        tool_name: 'tool-err', result: '{"error":"fail"}', error: true, runner_key: nil
      }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::ConversationStore).to have_received(:write_sticky_state) do |_, state|
        expect(state[:deferred_tool_calls]).to eq(0)
      end
    end

    it 'sets execution-tier stickiness for executed runner' do
      tc = deferred_tool('tool-a', 'github', 'issues')
      instance.injected_tool_map['tool-a'] = tc
      instance.pending_tool_history << { tool_name: 'tool-a', result: '{}', error: false, runner_key: nil }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::ConversationStore).to have_received(:write_sticky_state) do |_, state|
        runner_entry = state[:sticky_runners]['github_issues']
        expect(runner_entry[:tier]).to eq(:executed)
        expect(runner_entry[:expires_after_deferred_call]).to eq(1 + 5)  # deferred_count + window
      end
    end

    it 'sets trigger-tier stickiness only for freshly triggered keys (not re-injected)' do
      instance.freshly_triggered_keys = ['github_branches']
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::ConversationStore).to have_received(:write_sticky_state) do |_, state|
        branch_entry = state[:sticky_runners]['github_branches']
        expect(branch_entry[:tier]).to eq(:triggered)
        # snapshot=3, trigger_turns=2, +1 = 6
        expect(branch_entry[:expires_at_turn]).to eq(6)
      end
    end

    it 'does NOT refresh trigger window for runners not in freshly_triggered_keys' do
      # runner was re-injected (in @triggered_tools) but NOT freshly triggered
      instance.freshly_triggered_keys = []  # empty — nothing was freshly triggered
      instance.instance_variable_set(:@request, fake_request('c1'))

      allow(Legion::LLM::ConversationStore).to receive(:read_sticky_state)
        .and_return({ sticky_runners: { 'github_issues' => { tier: :triggered, expires_at_turn: 10 } } })
      instance.step_sticky_persist

      expect(Legion::LLM::ConversationStore).to have_received(:write_sticky_state) do |_, state|
        # expires_at_turn should remain 10, not refreshed
        expect(state[:sticky_runners]['github_issues'][:expires_at_turn]).to eq(10)
      end
    end

    it 'appends tool call records to tool_call_history' do
      instance.pending_tool_history << {
        tool_name: 'my-tool', result: '{"result":[1,2]}', error: false,
        runner_key: 'my_runner', args: { q: 'test' }
      }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::ConversationStore).to have_received(:write_sticky_state) do |_, state|
        entry = state[:tool_call_history].first
        expect(entry[:tool]).to eq('my-tool')
        expect(entry[:runner]).to eq('my_runner')
        expect(entry[:turn]).to eq(3)
      end
    end

    it 'trims tool_call_history to max_history_entries' do
      allow(instance).to receive(:max_history_entries).and_return(2)
      existing = Array.new(3) { |i| { tool: "t#{i}", runner: 'r', turn: i, args: {}, result: '{}', error: false } }
      allow(Legion::LLM::ConversationStore).to receive(:read_sticky_state)
        .and_return({ tool_call_history: existing })
      instance.pending_tool_history << { tool_name: 'new', result: '{}', error: false, runner_key: 'r', args: {} }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::ConversationStore).to have_received(:write_sticky_state) do |_, state|
        expect(state[:tool_call_history].size).to eq(2)
      end
    end

    it 'redacts sensitive arg keys' do
      instance.pending_tool_history << {
        tool_name: 'my-tool', result: '{}', error: false,
        runner_key: 'r', args: { api_key: 'secret123', owner: 'LegionIO' }
      }
      instance.instance_variable_set(:@request, fake_request('c1'))
      instance.step_sticky_persist

      expect(Legion::LLM::ConversationStore).to have_received(:write_sticky_state) do |_, state|
        entry = state[:tool_call_history].first
        expect(entry[:args][:api_key]).to eq('[REDACTED]')
        expect(entry[:args][:owner]).to eq('LegionIO')
      end
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec spec/legion/llm/pipeline/steps/sticky_persist_spec.rb --format documentation 2>&1 | tail -20
```

- [ ] **Step 3: Create `sticky_persist.rb`**

Create `lib/legion/llm/pipeline/steps/sticky_persist.rb`:

```ruby
# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module StickyPersist
          include Legion::Logging::Helper

          SENSITIVE_PARAM_NAMES = %w[
            api_key token secret password bearer_token
            access_token private_key secret_key auth_token credential
          ].freeze

          def step_sticky_persist
            return unless @sticky_turn_snapshot
            return unless sticky_enabled? && @request.conversation_id

            conv_id        = @request.conversation_id
            state          = ConversationStore.read_sticky_state(conv_id).dup
            runners        = (state[:sticky_runners] || {}).dup
            deferred_count = state[:deferred_tool_calls] || 0

            # Single Registry snapshot — one mutex acquisition for all lookups
            tool_snapshot = if defined?(::Legion::Tools::Registry)
                              ::Legion::Tools::Registry.all_tools
                                                       .each_with_object({}) { |t, h| h[t.tool_name] = t }
                            else
                              {}
                            end

            pending_snapshot = @pending_tool_history.dup
            completed        = pending_snapshot.select { |e| e[:result] && !e[:error] }

            executed_runner_keys = []
            deferred_call_count  = 0

            completed.each do |entry|
              tc  = @injected_tool_map[entry[:tool_name]] || tool_snapshot[entry[:tool_name]]
              next unless tc&.deferred?

              key = entry[:runner_key] || "#{tc.extension}_#{tc.runner}"
              executed_runner_keys << key
              deferred_call_count  += 1
            end

            executed_runner_keys.uniq!
            deferred_count               += deferred_call_count
            state[:deferred_tool_calls]   = deferred_count

            executed_runner_keys.each do |key|
              existing   = runners[key]
              new_expiry = deferred_count + execution_sticky_tool_calls
              runners[key] = {
                tier:                        :executed,
                expires_after_deferred_call: [existing&.dig(:expires_after_deferred_call) || 0, new_expiry].max
              }
            end

            (@freshly_triggered_keys - executed_runner_keys).each do |key|
              next if runners[key]&.dig(:tier) == :executed

              existing_expiry = runners.dig(key, :expires_at_turn) || 0
              new_expiry      = @sticky_turn_snapshot + trigger_sticky_turns + 1
              runners[key]    = { tier: :triggered, expires_at_turn: [existing_expiry, new_expiry].max }
            end

            state[:sticky_runners] = runners

            if pending_snapshot.any?
              history = (state[:tool_call_history] || []).dup

              pending_snapshot.each do |entry|
                next unless entry[:result]

                tc         = @injected_tool_map[entry[:tool_name]] || tool_snapshot[entry[:tool_name]]
                runner_key = entry[:runner_key] || (tc ? "#{tc.extension}_#{tc.runner}" : 'unknown')

                history << {
                  tool:   entry[:tool_name],
                  runner: runner_key,
                  turn:   @sticky_turn_snapshot,
                  args:   sanitize_args(truncate_args(entry[:args] || {})),
                  result: entry[:result].to_s[0, max_result_length],
                  error:  entry[:error] || false
                }
              end

              state[:tool_call_history] = history.last(max_history_entries)
            end

            ConversationStore.write_sticky_state(conv_id, state)
          rescue StandardError => e
            @warnings << "sticky_persist error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.step_sticky_persist')
          end

          private

          def sticky_enabled?
            Legion::Settings.dig(:llm, :tool_sticky, :enabled) != false
          end

          def trigger_sticky_turns
            Legion::Settings.dig(:llm, :tool_sticky, :trigger_turns) || 2
          end

          def execution_sticky_tool_calls
            Legion::Settings.dig(:llm, :tool_sticky, :execution_tool_calls) || 5
          end

          def max_history_entries
            Legion::Settings.dig(:llm, :tool_sticky, :max_history_entries) || 50
          end

          def max_result_length
            Legion::Settings.dig(:llm, :tool_sticky, :max_result_length) || 2000
          end

          def max_args_length
            Legion::Settings.dig(:llm, :tool_sticky, :max_args_length) || 500
          end

          def sanitize_args(args)
            args.each_with_object({}) do |(k, v), h|
              h[k] = SENSITIVE_PARAM_NAMES.include?(k.to_s.downcase) ? '[REDACTED]' : v
            end
          end

          def truncate_args(args)
            args.each_with_object({}) do |(k, v), h|
              h[k] = v.to_s.length > max_args_length ? "#{v.to_s[0, max_args_length]}\u2026" : v
            end
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec spec/legion/llm/pipeline/steps/sticky_persist_spec.rb --format documentation 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
git add lib/legion/llm/pipeline/steps/sticky_persist.rb spec/legion/llm/pipeline/steps/sticky_persist_spec.rb
git commit -m "add Steps::StickyPersist — single read-modify-write for sticky runners + tool history"
```

---

## Task 8: EnrichmentInjector — inject tool history before empty guard

**Files:**
- Modify: `lib/legion/llm/pipeline/enrichment_injector.rb`
- Test: `spec/legion/llm/pipeline/enrichment_injector_spec.rb`

- [ ] **Step 1: Write failing tests**

Add to `spec/legion/llm/pipeline/enrichment_injector_spec.rb`:

```ruby
describe 'tool:call_history enrichment' do
  it 'injects tool history even when no other enrichments are present' do
    result = described_class.inject(
      system:      'You are an assistant.',
      enrichments: { 'tool:call_history' => { content: 'Tools used: list_issues', data: {}, timestamp: Time.now } }
    )
    expect(result).to include('Tools used: list_issues')
  end

  it 'injects tool history after skill:active' do
    result = described_class.inject(
      system:      nil,
      enrichments: {
        'skill:active'        => 'You are a code reviewer.',
        'tool:call_history'   => { content: 'Tools used: list_issues', data: {}, timestamp: Time.now }
      }
    )
    skill_pos   = result.index('You are a code reviewer.')
    history_pos = result.index('Tools used: list_issues')
    expect(history_pos).to be > skill_pos
  end

  it 'does not inject when tool:call_history enrichment is absent' do
    result = described_class.inject(system: 'base', enrichments: {})
    expect(result).to eq('base')
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec spec/legion/llm/pipeline/enrichment_injector_spec.rb --format documentation 2>&1 | tail -15
```

- [ ] **Step 3: Update `enrichment_injector.rb`**

In `lib/legion/llm/pipeline/enrichment_injector.rb`, add the tool history block after the `skill:active` block and BEFORE the `return system if parts.empty?` guard:

```ruby
# Skill injection
if (skill = enrichments['skill:active'])
  parts << skill
end

# Tool call history — BEFORE the empty-parts guard so history reaches
# the LLM even when no other enrichments are present
if (history_block = enrichments.dig('tool:call_history', :content))
  parts << history_block
end

return system if parts.empty?
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec spec/legion/llm/pipeline/enrichment_injector_spec.rb --format documentation 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
git add lib/legion/llm/pipeline/enrichment_injector.rb spec/legion/llm/pipeline/enrichment_injector_spec.rb
git commit -m "inject tool:call_history enrichment before empty-parts guard in EnrichmentInjector"
```

---

## Task 9: Executor — wire everything together

**Files:**
- Modify: `lib/legion/llm/pipeline/executor.rb`
- Modify: `lib/legion/llm/pipeline/profile.rb`
- Test: `spec/legion/llm/pipeline/executor_spec.rb`

- [ ] **Step 1: Write failing tests**

Add to `spec/legion/llm/pipeline/executor_spec.rb`:

```ruby
describe 'sticky tool tracking ivars' do
  let(:request) { build_test_request }  # use existing test helper

  it 'initializes @sticky_turn_snapshot to nil' do
    executor = described_class.new(request)
    expect(executor.instance_variable_get(:@sticky_turn_snapshot)).to be_nil
  end

  it 'initializes @pending_tool_history as Concurrent::Array' do
    executor = described_class.new(request)
    expect(executor.instance_variable_get(:@pending_tool_history)).to be_a(Concurrent::Array)
  end

  it 'initializes @injected_tool_map as empty Hash' do
    executor = described_class.new(request)
    expect(executor.instance_variable_get(:@injected_tool_map)).to eq({})
  end

  it 'initializes @freshly_triggered_keys as empty Array' do
    executor = described_class.new(request)
    expect(executor.instance_variable_get(:@freshly_triggered_keys)).to eq([])
  end
end

describe '#inject_registry_tools' do
  it 'populates @injected_tool_map for always-loaded tools' do
    executor = described_class.new(build_test_request)
    session  = double('session', with_tool: nil)
    tool_class = double(tool_name: 'legion_do', description: '', input_schema: nil,
                        deferred?: false, extension: nil, runner: nil, sticky: true,
                        mcp_category: nil, mcp_tier: nil, respond_to?: false)
    allow(Legion::Tools::Registry).to receive(:tools).and_return([tool_class])
    allow(Legion::Tools::Registry).to receive(:deferred_tools).and_return([])
    allow(Legion::Tools::Registry).to receive(:respond_to?).and_return(false)

    executor.send(:inject_registry_tools, session)

    map = executor.instance_variable_get(:@injected_tool_map)
    # adapter.name is the sanitized name; for 'legion_do' it stays 'legion_do'
    expect(map.values).to include(tool_class)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec spec/legion/llm/pipeline/executor_spec.rb -e "sticky tool tracking" --format documentation 2>&1 | tail -15
```

- [ ] **Step 3: Update `executor.rb` — includes and ivars**

At the top of the `Executor` class (after existing includes), add:

```ruby
include Steps::StickyRunners
include Steps::ToolHistory
include Steps::StickyPersist
```

In `initialize`, add the four new ivars:

```ruby
@sticky_turn_snapshot    = nil
@pending_tool_history    = Concurrent::Array.new
@pending_tool_history_mutex = Mutex.new
@injected_tool_map       = {}
@freshly_triggered_keys  = []
```

- [ ] **Step 4: Update step arrays**

Replace the three constants (`STEPS`, `PRE_PROVIDER_STEPS`, `POST_PROVIDER_STEPS`):

```ruby
PRE_PROVIDER_STEPS = %i[
  tracing_init idempotency conversation_uuid context_load
  rbac classification billing gaia_advisory tier_assignment rag_context
  trigger_match sticky_runners skill_injector tool_history_inject tool_discovery
  routing request_normalization token_budget
].freeze

POST_PROVIDER_STEPS = %i[
  response_normalization metering debate confidence_scoring
  tool_calls sticky_persist
  context_store post_response knowledge_capture response_return
].freeze

STEPS = (PRE_PROVIDER_STEPS + %i[provider_call] + POST_PROVIDER_STEPS).freeze
```

- [ ] **Step 5: Update `inject_registry_tools` — add map population to all three loops**

In `inject_registry_tools`, add `@injected_tool_map[adapter.name] = tool_class` at each point where `session.with_tool(adapter)` is called. There are three loops:

Loop 1 (always-loaded, around line 101–107):
```ruby
::Legion::Tools::Registry.tools.each do |tool_class|
  adapter = ToolAdapter.new(tool_class)
  @injected_tool_map[adapter.name] = tool_class  # ADD THIS
  session.with_tool(adapter)
  injected_names << adapter.name
  ...
```

Loop 2 (trigger-matched, around line 111–120):
```ruby
@triggered_tools.each do |tool_class|
  adapter = ToolAdapter.new(tool_class)
  next if injected_names.include?(adapter.name)
  @injected_tool_map[adapter.name] = tool_class  # ADD THIS
  session.with_tool(adapter)
  injected_names << adapter.name
  ...
```

Loop 3 (requested-deferred, around line 127–137):
```ruby
deferred.each do |tool_class|
  adapter = ToolAdapter.new(tool_class)
  next unless requested.include?(adapter.name)
  @injected_tool_map[adapter.name] = tool_class  # ADD THIS
  session.with_tool(adapter)
  injected_names << adapter.name
  ...
```

- [ ] **Step 6: Update `emit_tool_call_event` — push partial entry**

Find `def emit_tool_call_event(tool_call, round)` (around line 775). After extracting `tc_id`, `tc_name`, `tc_args`, add before the existing `Thread.current` assignments:

```ruby
@pending_tool_history_mutex.synchronize do
  pending_index = @pending_tool_history.size
  @pending_tool_history << {
    tool_call_id:  tc_id,
    pending_index: pending_index,
    tool_name:     tc_name,
    args:          tc_args,
    result:        nil,
    error:         false,
    runner_key:    nil
  }
  Thread.current[:legion_current_tool_history_index] = pending_index
end
```

- [ ] **Step 7: Update `emit_tool_result_event` — fill result on partial entry**

Find `def emit_tool_result_event(tool_result)` (around line 795). After extracting `tc_id` and `raw`, add:

```ruby
@pending_tool_history_mutex.synchronize do
  entry = @pending_tool_history.find { |e| e[:tool_call_id] == tc_id && e[:result].nil? }
  entry ||= @pending_tool_history[Thread.current[:legion_current_tool_history_index]]
  if entry
    entry[:result] = raw.is_a?(String) ? raw : raw.to_s
    entry[:error]  = raw.is_a?(Hash) && (raw[:error] || raw['error']) ? true : false
  end
end
```

- [ ] **Step 8: Update `step_tool_calls` — append to `@pending_tool_history`**

In `lib/legion/llm/pipeline/steps/tool_calls.rb`, inside the tool dispatch loop after `result = ToolDispatcher.dispatch(...)`, add:

```ruby
lex_normalized = (source[:lex] || '').delete_prefix('lex-').tr('-', '_')
runner_key     = source[:type] == :extension ? "#{lex_normalized}_#{source[:runner]}" : nil
result_string  = result[:result].is_a?(String) ? result[:result] : Legion::JSON.dump(result[:result] || {})
@pending_tool_history << {
  tool_call_id:  tool_call_id,
  pending_index: @pending_tool_history.size,
  tool_name:     tool_name,
  args:          tc[:arguments] || tc['arguments'] || {},
  result:        result_string,
  error:         result[:status] == :error,
  runner_key:    runner_key
}
```

- [ ] **Step 9: Update profile skip lists**

In `lib/legion/llm/pipeline/profile.rb`, add `:sticky_runners, :tool_history_inject, :sticky_persist` to `GAIA_SKIP`, `SYSTEM_SKIP`, `QUICK_REPLY_SKIP`, and `SERVICE_SKIP`.

- [ ] **Step 10: Run full executor test suite**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec spec/legion/llm/pipeline/executor_spec.rb --format progress 2>&1 | tail -10
```

- [ ] **Step 11: Run full suite**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec --format progress 2>&1 | tail -10
bundle exec rubocop lib/legion/llm/pipeline/executor.rb lib/legion/llm/pipeline/profile.rb lib/legion/llm/pipeline/steps/tool_calls.rb 2>&1 | tail -5
```

Fix any rubocop offenses before committing.

- [ ] **Step 12: Commit**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
git add lib/legion/llm/pipeline/executor.rb \
        lib/legion/llm/pipeline/profile.rb \
        lib/legion/llm/pipeline/steps/tool_calls.rb \
        spec/legion/llm/pipeline/executor_spec.rb
git commit -m "wire sticky runner steps into Executor — ivars, step arrays, inject map, emit callbacks, profile skips"
```

---

## Task 10: Integration — run full suites and final rubocop

**Files:** No new files — validation only

- [ ] **Step 1: Run full legion-llm suite**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rspec --format progress 2>&1 | tail -10
```

Expected: 0 new failures (existing suite baseline was clean)

- [ ] **Step 2: Run full LegionIO suite**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
bundle exec rspec --format progress 2>&1 | tail -10
```

Expected: same pre-existing failure count as before (6 failures in fleet_command + embedding_cache)

- [ ] **Step 3: Run rubocop on all new/modified files**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/legion-llm
bundle exec rubocop \
  lib/legion/llm/conversation_store.rb \
  lib/legion/llm/pipeline/enrichment_injector.rb \
  lib/legion/llm/pipeline/executor.rb \
  lib/legion/llm/pipeline/profile.rb \
  lib/legion/llm/pipeline/steps/sticky_runners.rb \
  lib/legion/llm/pipeline/steps/tool_history.rb \
  lib/legion/llm/pipeline/steps/sticky_persist.rb \
  lib/legion/llm/pipeline/steps/tool_calls.rb \
  2>&1 | tail -10

cd /Users/matt.iverson@optum.com/rubymine/legion/LegionIO
bundle exec rubocop \
  lib/legion/tools/base.rb \
  lib/legion/tools/discovery.rb \
  lib/legion/extensions/core.rb \
  2>&1 | tail -10
```

Expected: 0 offenses on all files. Fix any before committing.

- [ ] **Step 4: Final commit if any rubocop fixes were needed**

```bash
# In each repo, if any fixes were made:
git add -u
git commit -m "rubocop fixes for sticky runner implementation"
```

---

## Task 11: Patch Homebrew Cellar for local testing

**Files:** Cellar copies of modified gems

- [ ] **Step 1: Find the installed gem paths**

```bash
find /opt/homebrew/Cellar/legionio -name "conversation_store.rb" -path "*/legion-llm-*" 2>/dev/null
find /opt/homebrew/Cellar/legionio -name "executor.rb" -path "*/legion-llm-*" 2>/dev/null
find /opt/homebrew/Cellar/legionio -name "enrichment_injector.rb" 2>/dev/null
find /opt/homebrew/Cellar/legionio -name "base.rb" -path "*/tools*" 2>/dev/null
find /opt/homebrew/Cellar/legionio -name "discovery.rb" -path "*/tools*" 2>/dev/null
find /opt/homebrew/Cellar/legionio -name "core.rb" -path "*/extensions*" 2>/dev/null
```

- [ ] **Step 2: Copy new step files to Cellar**

```bash
CELLAR_LLM=$(find /opt/homebrew/Cellar/legionio -name "legion-llm-*.gemspec" -exec dirname {} \; | head -1)/lib/legion/llm/pipeline/steps

cp lib/legion/llm/pipeline/steps/sticky_runners.rb "$CELLAR_LLM/"
cp lib/legion/llm/pipeline/steps/tool_history.rb   "$CELLAR_LLM/"
cp lib/legion/llm/pipeline/steps/sticky_persist.rb "$CELLAR_LLM/"
```

- [ ] **Step 3: Copy modified files to Cellar**

Replace the Cellar copies of:
- `conversation_store.rb`
- `enrichment_injector.rb`
- `executor.rb`
- `profile.rb`
- `steps/tool_calls.rb`
- LegionIO: `tools/base.rb`, `tools/discovery.rb`, `extensions/core.rb`

Use the paths found in Step 1 and `cp` from source to Cellar.

- [ ] **Step 4: Restart the daemon and test**

```
! brew services restart legionio
```

Then test in legion-interlink: start a conversation, ask about GitHub issues (should trigger injection), call a tool, verify the next turn still has the runner injected, and verify history appears in context.

---

## Post-Implementation Notes

- **Release ordering**: LegionIO changes (Tasks 1–3) must be released before or simultaneously with legion-llm changes (Tasks 4–9)
- **Settings to tune**: `llm.tool_sticky.trigger_turns` (default 2), `llm.tool_sticky.execution_tool_calls` (default 5)
- **Known limitations**: LRU eviction (256 conv limit), concurrent same-conv race, external MCP tools, caller-provided `@request.tools` — all documented in spec "Not Included"
