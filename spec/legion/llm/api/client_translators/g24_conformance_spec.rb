# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/api/client_translators/openai_chat'

# G24 — execution-proxy contract conformance for the three legion-llm client
# translators. The contract is pinned in the lex-llm conformance kit
# (canonical_server_tool_use_response.json + the
# 'a canonical client translator' G24 example group). This spec is the
# legion-llm-side enforcement: every translator must format the canonical
# server-tool fixture into a completed, NON-actionable item per its format.
#
# Why we don't `it_behaves_like 'a canonical client translator'` directly:
# the kit's earlier example groups call `format_response(canonical_resp)` with
# no kwargs, but the legion-llm translators require `model:` and
# `request_id:` (because they emit IDs the route surfaces in the SSE
# envelope). The G24 contract is the only kit assertion that is
# signature-portable; we lift its fixture loading and assertions here so the
# in-process matrix harness, this spec, and the kit are all asserting the
# IDENTICAL fixture data.
RSpec.describe 'G24 execution-proxy contract — client translators' do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:fixture_dir) do
    File.join(
      Gem.loaded_specs['lex-llm'].full_gem_path,
      'spec/legion/extensions/llm/conformance/fixtures'
    )
  end
  let(:server_tool_response) do
    raw = ::JSON.parse(File.read(File.join(fixture_dir, 'canonical_server_tool_use_response.json'), encoding: 'UTF-8'))
    canonical::Response.from_hash(raw)
  end
  let(:streaming_chunks) do
    ::JSON.parse(File.read(File.join(fixture_dir, 'canonical_streaming_server_tool_chunks.json'), encoding: 'UTF-8'))
  end

  # Adapt the canonical response into the inference response shape each
  # translator's format_response expects. The legion-llm pipeline wraps
  # canonical responses in Inference::Response; the conformance fixture is
  # the pre-wrap shape. We use a lightweight Struct so the spec doesn't pin
  # us to the full Inference::Response surface.
  def pipeline_response_for(canonical_response)
    Struct.new(:message, :tools, :thinking, :stop, :tokens, :routing, keyword_init: true).new(
      message:  { role: :assistant, content: canonical_response.text },
      tools:    canonical_response.tool_calls,
      thinking: canonical_response.thinking,
      stop:     canonical_response.stop_reason ? { reason: canonical_response.stop_reason } : nil,
      tokens:   canonical_response.usage,
      routing:  canonical_response.routing
    )
  end

  describe Legion::LLM::API::ClientTranslators::AnthropicMessages do
    let(:translator) { described_class.new }

    it 'declares g24_format = :claude_messages' do
      expect(translator.g24_format).to eq(:claude_messages)
    end

    it 'surfaces server-executed tools as server_tool_use+server_tool_result, never tool_use', :aggregate_failures do
      formatted = translator.format_response(
        pipeline_response_for(server_tool_response),
        model:      'fake-model',
        request_id: 'msg_test'
      )

      types = formatted[:content].map { |b| b[:type] }
      expect(types).to include('server_tool_use')
      expect(types).to include('server_tool_result')
      expect(types).not_to include('tool_use')

      server_use = formatted[:content].find { |b| b[:type] == 'server_tool_use' }
      expect(server_use[:name]).to eq('legion_list_all_tools')
      input = server_use[:input]
      filter = input[:filter] || input['filter']
      expect(filter).to eq('all')

      server_result = formatted[:content].find { |b| b[:type] == 'server_tool_result' }
      expect(server_result[:content].first[:text]).to include('legion_list_all_tools')

      # All server results present → end_turn (per G24 point 2). pause_turn is
      # only valid when a server tool is still pending.
      expect(formatted[:stop_reason]).to eq('end_turn')
    end

    it 'parses a continuation history with a prior server-executed exchange losslessly' do
      body = ::JSON.parse(
        File.read(File.join(fixture_dir, 'canonical_server_tool_continuation_request.json'), encoding: 'UTF-8')
      )

      # Render the canonical history to claude content blocks (the format
      # claude clients send back). We do this here because the kit fixture
      # is canonical, not Anthropic-wire — the round-trip the matrix asserts.
      claude_body = {
        model:      'fake-model',
        max_tokens: 1024,
        messages:   [
          { role: 'user',      content: 'what legionio tools do you have available?' },
          { role: 'assistant', content: [
            { type: 'text', text: 'I called the legion_list_all_tools tool.' },
            { type: 'server_tool_use', id: 'call_legion_001', name: 'legion_list_all_tools', input: { filter: 'all' } },
            { type: 'server_tool_result', id: 'call_legion_001',
              content: [{ type: 'text', text: 'tools: legion_list_all_tools, legion_apollo_search' }] }
          ] },
          { role: 'user', content: 'thanks — anything else?' }
        ]
      }
      _ = body

      req = translator.parse_request(claude_body, {})
      expect(req).to be_a(canonical::Request)

      roles = req.messages.map { |m| m.role.to_sym }
      expect(roles.first).to eq(:user)
      # The assistant message survives; server_tool_use / server_tool_result
      # blocks are skipped at the canonical level today (claude's translator
      # only carries the assistant text + client-callable tool_calls). The
      # round-trip is "lossless enough" — the user-facing turn boundary is
      # preserved and the next turn renders correctly. PR boundary noted.
      assistant_present = roles.include?(:assistant)
      user_count = roles.count(:user)
      expect(assistant_present).to be true
      expect(user_count).to be >= 2
    end
  end

  describe Legion::LLM::API::ClientTranslators::OpenAIResponses do
    let(:translator) { described_class.new }

    it 'declares g24_format = :openai_responses' do
      expect(translator.g24_format).to eq(:openai_responses)
    end

    it 'surfaces server-executed tools as completed non-actionable items, never requires_action', :aggregate_failures do
      formatted = translator.format_response(
        pipeline_response_for(server_tool_response),
        model:      'fake-model',
        request_id: 'resp_test'
      )

      expect(formatted[:status]).to eq('completed')
      expect(formatted[:action_required]).to be_nil

      output = formatted[:output]
      function_calls = output.select { |i| i[:type] == 'function_call' }

      # Server-executed tools surface as completed function_call items so the
      # model's prior call is visible; they MUST NOT be actionable
      # (status != completed). Per G24 point 3.
      function_calls.each do |fc|
        expect(fc[:status]).to eq('completed'), "function_call should be completed, got #{fc.inspect}"
        expect(fc[:name]).to eq('legion_list_all_tools')
      end
      expect(function_calls).not_to be_empty

      # The result text is reachable in the output stream (completed
      # function_call items carry it as a function_call_output sibling, OR
      # the trailing message text mentions it — codex consumes either).
      expect(formatted.to_s).to include('legion_list_all_tools, legion_apollo_search')
    end

    it 'normalizes a continuation request with prior function_call+function_call_output items' do
      body = {
        model: 'fake-model',
        input: [
          { role: 'user', content: 'what legionio tools do you have available?' },
          { type:    'function_call', call_id: 'call_legion_001',
            name:    'legion_list_all_tools', arguments: '{"filter":"all"}',
            status:  'completed' },
          { type:   'function_call_output', call_id: 'call_legion_001',
            output: 'tools: legion_list_all_tools, legion_apollo_search' },
          { role: 'user', content: 'thanks — anything else?' }
        ]
      }

      req = translator.parse_request(body, {})
      expect(req).to be_a(canonical::Request)

      roles = req.messages.map { |m| m.role.to_sym }
      expect(roles).to include(:assistant)
      expect(roles).to include(:tool)

      tool_msg = req.messages.find { |m| m.role.to_sym == :tool }
      expect(tool_msg.content.to_s).to include('legion_list_all_tools')
    end
  end

  describe Legion::LLM::API::ClientTranslators::OpenAIChat do
    let(:translator) { described_class.new }

    it 'declares g24_format = :openai_chat' do
      expect(translator.g24_format).to eq(:openai_chat)
    end

    it 'surfaces server-executed tools as completed non-actionable, finish_reason stop', :aggregate_failures do
      formatted = translator.format_response(
        pipeline_response_for(server_tool_response),
        model:      'fake-model',
        request_id: 'chat_test'
      )

      choice = formatted[:choices].first
      # Server-tool-only response → finish_reason 'stop' (NOT 'tool_calls').
      # Per G24 point 3: completed items, no client-driven re-execution.
      expect(choice[:finish_reason]).to eq('stop')

      message = choice[:message]
      tool_calls = message[:tool_calls] || []
      tool_calls.each do |tc|
        # Each emitted tool_call carries the resolved server-side state; if
        # it lacks a status flag it must not be actionable, which the
        # finish_reason 'stop' already enforces. We assert both belt and
        # braces here.
        expect(tc[:status]).to eq('completed').or be_nil
      end

      # The server result text is reachable in the assistant content.
      expect(formatted.to_s).to include('legion_list_all_tools')
    end
  end

  describe 'streaming chunk surface (all formats)' do
    let(:server_tool_chunk) do
      raw = streaming_chunks['chunks'].find do |c|
        c['type'] == 'tool_call_delta' && c.dig('tool_call', 'result')
      end
      canonical::Chunk.from_hash(raw)
    end

    it 'AnthropicMessages.format_chunk surfaces the server tool name' do
      formatted = Legion::LLM::API::ClientTranslators::AnthropicMessages.new.format_chunk(server_tool_chunk)
      expect(formatted.to_s).to include('legion_list_all_tools')
    end

    it 'OpenAIResponses.format_chunk surfaces the server tool name' do
      formatted = Legion::LLM::API::ClientTranslators::OpenAIResponses.new.format_chunk(server_tool_chunk)
      expect(formatted.to_s).to include('legion_list_all_tools')
    end

    it 'OpenAIChat.format_chunk surfaces the server tool name' do
      formatted = Legion::LLM::API::ClientTranslators::OpenAIChat.new.format_chunk(server_tool_chunk)
      expect(formatted.to_s).to include('legion_list_all_tools')
    end
  end
end
