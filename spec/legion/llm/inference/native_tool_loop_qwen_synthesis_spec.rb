# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/native_tool_loop'

# Failing-test for the legionio-e2e codex/vllm tool_call regression.
# Live qwen3.6-27b on vLLM emits tool calls as plain text — but the format
# is NOT structured tool_calls AND is nondeterministic across runs.
# Captured evidence (codex/vllm tool_call, run 3 times in sequence):
#
#   run 1 (recoverable): "<bash>ls -la</bash>"
#   run 2 (UNRECOVERABLE): "Running `ls -la`..."   — no tool markup at all
#   run 3 (recoverable): "<bash>ls -la</bash>"
#
# The previous synthesizer fix in this spec assumed a different markup
# (`<tool_use_name>bash</tool_use_name>...<tool_use_value>...</tool_use_value>`)
# captured from a stale recording — that pattern does NOT fire on the
# current model output. Replaced with the actual `<TOOL>args</TOOL>` form.
#
# Synthesizer behavior pinned here:
#   * `<bash>ls -la</bash>` where `bash` is in native_dispatch_tools and
#     declares a single required string param → synthesize a function_call
#     with that param set to the wrapped text.
#   * Tools with multi-param schemas don't synthesize from a single
#     wrapped tag (we don't know which param the text belongs to).
#   * Plain narrative text (no tags) returns [] — that run is
#     unrecoverable; the codex/vllm tool_call cell is therefore
#     NONDETERMINISTIC and may still fail when qwen picks the
#     no-markup path.
#
# Forced-choice JSON synthesis is preserved (legacy path, unchanged).
RSpec.describe 'NativeToolLoop qwen markup tool synthesis' do
  let(:host_class) do
    Class.new do
      include Legion::Logging::Helper
      include Legion::LLM::Inference::NativeToolLoop

      attr_accessor :native_tool_prefs_value, :native_dispatch_tools_value

      def native_tool_prefs = @native_tool_prefs_value
      def native_dispatch_tools = @native_dispatch_tools_value || {}

      # Expose the otherwise-private synthesizer for direct testing.
      public :maybe_synthesize_tool_call_from_content
    end
  end

  # Real shape: native_dispatch_tools is Hash<Symbol, Hash> per
  # executor/tool_injection.rb:65 — `tool.name.to_sym, tool.to_h`.
  let(:bash_tool_hash) do
    {
      name:        'bash',
      description: 'Run a shell command',
      parameters:  {
        type:       'object',
        properties: { command: { type: 'string' } },
        required:   ['command']
      }
    }
  end

  let(:host) do
    instance = host_class.new
    instance.native_tool_prefs_value = nil
    instance.native_dispatch_tools_value = { bash: bash_tool_hash }
    instance
  end

  def canonical_response_with(text)
    canonical = Legion::Extensions::Llm::Canonical
    canonical::Response.build(
      text:        text,
      usage:       canonical::Usage.new(input_tokens: 1, output_tokens: 1, cache_read_tokens: 0,
                                        cache_write_tokens: 0, thinking_tokens: 0, units: {}),
      stop_reason: :end_turn,
      model:       'qwen3.6-27b',
      metadata:    {}
    )
  end

  describe 'recoverable runs (captured live from qwen3.6-27b)' do
    it 'synthesizes from the <bash>ls -la</bash> form (single-required-string-param tool)' do
      result = canonical_response_with('<bash>ls -la</bash>')

      synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

      expect(synthesized.size).to eq(1)
      expect(synthesized.first[:name]).to eq('bash')
      expect(synthesized.first[:arguments]).to eq('command' => 'ls -la')
      expect(synthesized.first[:id]).to start_with('call_')
    end

    # Captured 2026-06-12 from
    # legionio-e2e/results/codex/vllm_multi_turn_tool_round_trip_responses_api_*_response.json
    # qwen sometimes appends a colon to the tag name. Tag still maps to a
    # known tool; the inner text is still the single-arg value.
    it 'synthesizes from the <bash:>ls -la</bash:> trailing-punct variant' do
      result = canonical_response_with('<bash:>ls -la</bash:>')

      synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

      expect(synthesized.size).to eq(1)
      expect(synthesized.first[:name]).to eq('bash')
      expect(synthesized.first[:arguments]).to eq('command' => 'ls -la')
    end
  end

  describe 'unrecoverable runs (captured live)' do
    it 'returns [] for plain narrative text with no tool markup' do
      result = canonical_response_with('Running `ls -la`...')

      synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

      expect(synthesized).to eq([])
    end
  end

  describe 'safety bounds' do
    it 'returns [] when the tag name is not in native_dispatch_tools' do
      host.native_dispatch_tools_value = { other_tool: bash_tool_hash }
      result = canonical_response_with('<bash>ls -la</bash>')

      synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

      expect(synthesized).to eq([])
    end

    it 'returns [] when the named tool has multiple required params (ambiguous)' do
      multi_param_hash = {
        name:        'bash',
        description: 'Run a shell command',
        parameters:  {
          type:       'object',
          properties: { command: { type: 'string' }, cwd: { type: 'string' } },
          required:   %w[command cwd]
        }
      }
      host.native_dispatch_tools_value = { bash: multi_param_hash }
      result = canonical_response_with('<bash>ls -la</bash>')

      synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

      expect(synthesized).to eq([])
    end
  end

  describe 'regression guard' do
    it 'preserves forced-choice JSON synthesis' do
      host.native_tool_prefs_value = { choice: :bash }
      result = canonical_response_with('{"command":"ls -la"}')

      synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

      expect(synthesized.size).to eq(1)
      expect(synthesized.first[:name]).to eq('bash')
      expect(synthesized.first[:arguments]).to eq('command' => 'ls -la')
    end
  end

  # Pattern 4: leaked chat-template tool-call token. Some model chat templates
  # (observed live with gemma served via vLLM; ledger rows 337049/337111/337145/
  # 337174, 2026-07) emit tool-call intent as a RAW LITERAL TOKEN in content
  # instead of the structured tool_calls field:
  #
  #   <|tool_call>call:NAME{key:<|"|>value<|"|>,key2:<|"|>value2<|"|>}<tool_call|>
  #
  # <|"|> is the string delimiter. Without synthesis this token reaches the
  # client verbatim (a "tool call" printed as text, nothing executed). The
  # strings below are captured verbatim from the ledger.
  describe 'leaked chat-template token synthesis (captured live from gemma/vLLM)' do
    let(:browser_tool_hash) do
      {
        name:        'browser',
        description: 'Drive a headless browser',
        parameters:  {
          type:       'object',
          properties: { action: { type: 'string' }, code: { type: 'string' }, name: { type: 'string' } },
          required:   ['action']
        }
      }
    end

    it 'synthesizes a single-arg leaked bash token (ledger row 337111)' do
      result = canonical_response_with('<|tool_call>call:bash{command:<|"|>rtk lsof -i :6767<|"|>}<tool_call|>')

      synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

      expect(synthesized.size).to eq(1)
      expect(synthesized.first[:name]).to eq('bash')
      expect(synthesized.first[:arguments]).to eq('command' => 'rtk lsof -i :6767')
      expect(synthesized.first[:id]).to start_with('call_')
    end

    it 'synthesizes a multi-arg leaked bash token (ledger row 337174)' do
      result = canonical_response_with(
        '<|tool_call>call:bash{command:<|"|>./update_repos.sh<|"|>,description:<|"|>Run the automation script<|"|>}<tool_call|>'
      )

      synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

      expect(synthesized.size).to eq(1)
      expect(synthesized.first[:name]).to eq('bash')
      expect(synthesized.first[:arguments]).to eq(
        'command' => './update_repos.sh', 'description' => 'Run the automation script'
      )
    end

    it 'handles values with embedded quotes and newlines (browser code, ledger row 337145)' do
      host.native_dispatch_tools_value = { browser: browser_tool_hash }
      # The `code` value contains regular double-quotes and \n — this is where a
      # gsub-then-parse-as-object approach breaks; the scan-based parser must not.
      result = canonical_response_with(
        %(<|tool_call>call:browser{action:<|"|>run<|"|>,code:<|"|>await tab.goto('https://x.com');\nconst c = "y";\nreturn c;<|"|>,name:<|"|>paseo_repo<|"|>}<tool_call|>)
      )

      synthesized = host.maybe_synthesize_tool_call_from_content(result, 0)

      expect(synthesized.size).to eq(1)
      expect(synthesized.first[:name]).to eq('browser')
      expect(synthesized.first[:arguments]['action']).to eq('run')
      expect(synthesized.first[:arguments]['name']).to eq('paseo_repo')
      expect(synthesized.first[:arguments]['code']).to include(%(const c = "y";))
      expect(synthesized.first[:arguments]['code']).to include("\n")
    end

    it 'returns [] when the leaked tool name is not in native_dispatch_tools' do
      result = canonical_response_with('<|tool_call>call:unknown_tool{command:<|"|>ls<|"|>}<tool_call|>')

      expect(host.maybe_synthesize_tool_call_from_content(result, 0)).to eq([])
    end

    it 'does not fire on plain narrative text that merely mentions a tool' do
      result = canonical_response_with('I will run bash to list files.')

      expect(host.maybe_synthesize_tool_call_from_content(result, 0)).to eq([])
    end
  end
end
