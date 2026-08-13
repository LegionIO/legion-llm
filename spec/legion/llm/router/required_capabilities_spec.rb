# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/required_capabilities'

RSpec.describe Legion::LLM::Router::RequiredCapabilities do
  # HOW REQUESTS ARE CONSTRUCTED
  # The current worktree request.rb (pre-§7.2) does not yet require routing_settings_snapshot
  # or trusted_constraints, so we use Legion::LLM::Inference::Request.build directly with
  # the fields RequiredCapabilities reads. All build kwargs are optional with sensible defaults.
  def build_request(**)
    Legion::LLM::Inference::Request.build(messages: [], **)
  end

  let(:plain_request) { build_request }

  describe '.call' do
    # -----------------------------------------------------------------------
    # Operation base capabilities
    # -----------------------------------------------------------------------
    context 'operation base capabilities' do
      it 'chat produces no base capabilities on an empty request' do
        expect(described_class.call(request: plain_request, operation: :chat)).to eq([])
      end

      it 'stream_chat requires :streaming' do
        result = described_class.call(request: plain_request, operation: :stream_chat)
        expect(result).to include(:streaming)
      end

      it 'embed requires :embedding' do
        expect(described_class.call(request: plain_request, operation: :embed)).to include(:embedding)
      end

      it 'image requires :image' do
        expect(described_class.call(request: plain_request, operation: :image)).to include(:image)
      end

      it 'transcribe requires :audio_transcription' do
        expect(described_class.call(request: plain_request, operation: :transcribe)).to include(:audio_transcription)
      end

      it 'translate produces no base capabilities' do
        expect(described_class.call(request: plain_request, operation: :translate)).to eq([])
      end

      it 'speak requires :audio_speech' do
        expect(described_class.call(request: plain_request, operation: :speak)).to include(:audio_speech)
      end

      it 'moderate requires :moderation' do
        expect(described_class.call(request: plain_request, operation: :moderate)).to include(:moderation)
      end

      it 'count_tokens produces no base capabilities' do
        expect(described_class.call(request: plain_request, operation: :count_tokens)).to eq([])
      end
    end

    # -----------------------------------------------------------------------
    # Shape trigger: tools
    # -----------------------------------------------------------------------
    context ':tools shape trigger' do
      it 'triggered when the tools array is nonempty' do
        req = build_request(tools: [{ name: 'web_search', description: 'Search the web' }])
        expect(described_class.call(request: req, operation: :chat)).to include(:tools)
      end

      it 'not triggered when tools is nil' do
        req = build_request(tools: nil)
        expect(described_class.call(request: req, operation: :chat)).not_to include(:tools)
      end

      it 'not triggered when tools is an empty array' do
        req = build_request(tools: [])
        expect(described_class.call(request: req, operation: :chat)).not_to include(:tools)
      end

      it 'triggered when tool_choice mode forces a specific tool (:tool)' do
        req = build_request(tool_choice: { mode: :tool, name: 'web_search' })
        expect(described_class.call(request: req, operation: :chat)).to include(:tools)
      end

      it 'triggered when tool_choice mode forces any tool use (:any)' do
        req = build_request(tool_choice: { mode: :any })
        expect(described_class.call(request: req, operation: :chat)).to include(:tools)
      end

      it 'not triggered when tool_choice mode is :auto' do
        req = build_request(tools: nil, tool_choice: { mode: :auto })
        expect(described_class.call(request: req, operation: :chat)).not_to include(:tools)
      end

      it 'not triggered when tool_choice mode is :none' do
        req = build_request(tools: nil, tool_choice: { mode: :none })
        expect(described_class.call(request: req, operation: :chat)).not_to include(:tools)
      end

      it 'triggered when any message content block is :tool_use' do
        messages = [
          { role: :assistant, content: [
            { type: :tool_use, id: 'tu_1', name: 'web_search', input: { query: 'hello' } }
          ] }
        ]
        req = build_request(messages: messages)
        expect(described_class.call(request: req, operation: :chat)).to include(:tools)
      end

      it 'triggered when any message content block is :tool_result' do
        messages = [
          { role: :user, content: [
            { type: :tool_result, tool_use_id: 'tu_1', content: 'result text' }
          ] }
        ]
        req = build_request(messages: messages)
        expect(described_class.call(request: req, operation: :chat)).to include(:tools)
      end

      it 'not triggered when messages have only :text content blocks' do
        messages = [{ role: :user, content: [{ type: :text, text: 'Hello' }] }]
        req = build_request(messages: messages)
        expect(described_class.call(request: req, operation: :chat)).not_to include(:tools)
      end
    end

    # -----------------------------------------------------------------------
    # Shape trigger: thinking
    # -----------------------------------------------------------------------
    context ':thinking shape trigger' do
      it 'triggered when thinking config is { enabled: true }' do
        req = build_request(thinking: { enabled: true, budget_tokens: 1024 })
        expect(described_class.call(request: req, operation: :chat)).to include(:thinking)
      end

      it 'triggered when thinking config is a non-empty hash without explicit enabled key' do
        req = build_request(thinking: { budget_tokens: 2048 })
        expect(described_class.call(request: req, operation: :chat)).to include(:thinking)
      end

      it 'not triggered when thinking is nil' do
        req = build_request(thinking: nil)
        expect(described_class.call(request: req, operation: :chat)).not_to include(:thinking)
      end

      it 'not triggered when thinking is explicitly disabled' do
        req = build_request(thinking: { enabled: false })
        expect(described_class.call(request: req, operation: :chat)).not_to include(:thinking)
      end

      it 'triggered when any message content block is :thinking' do
        messages = [
          { role: :assistant, content: [
            { type: :thinking, thinking: 'Let me reason through this step by step...' }
          ] }
        ]
        req = build_request(messages: messages)
        expect(described_class.call(request: req, operation: :chat)).to include(:thinking)
      end
    end

    # -----------------------------------------------------------------------
    # Shape trigger: vision
    # -----------------------------------------------------------------------
    context ':vision shape trigger' do
      it 'triggered by an :image content block (Anthropic canonical shape)' do
        messages = [
          { role: :user, content: [
            { type: :image, source: { type: :base64, media_type: 'image/png', data: 'abc==' } }
          ] }
        ]
        req = build_request(messages: messages)
        expect(described_class.call(request: req, operation: :chat)).to include(:vision)
      end

      it 'triggered by an :image_url content block (OpenAI canonical shape)' do
        messages = [
          { role: :user, content: [
            { type: :image_url, image_url: { url: 'https://example.com/photo.png' } }
          ] }
        ]
        req = build_request(messages: messages)
        expect(described_class.call(request: req, operation: :chat)).to include(:vision)
      end

      it 'not triggered when messages have only :text content blocks' do
        messages = [{ role: :user, content: [{ type: :text, text: 'describe this image' }] }]
        req = build_request(messages: messages)
        expect(described_class.call(request: req, operation: :chat)).not_to include(:vision)
      end

      it 'not triggered when message content is a plain String (no content blocks)' do
        messages = [{ role: :user, content: 'just a plain string' }]
        req = build_request(messages: messages)
        expect(described_class.call(request: req, operation: :chat)).not_to include(:vision)
      end
    end

    # -----------------------------------------------------------------------
    # Shape trigger: structured_output
    # -----------------------------------------------------------------------
    context ':structured_output shape trigger' do
      it 'triggered when response_format type is :json_object' do
        req = build_request(response_format: { type: :json_object })
        expect(described_class.call(request: req, operation: :chat)).to include(:structured_output)
      end

      it 'triggered when response_format type is :json_schema' do
        req = build_request(response_format: { type: :json_schema, schema: { type: 'object' } })
        expect(described_class.call(request: req, operation: :chat)).to include(:structured_output)
      end

      it 'triggered when response_format type is the string "json_object"' do
        req = build_request(response_format: { type: 'json_object' })
        expect(described_class.call(request: req, operation: :chat)).to include(:structured_output)
      end

      it 'triggered when response_format contains a nonempty schema regardless of type field' do
        req = build_request(response_format: { schema: { properties: { name: { type: 'string' } } } })
        expect(described_class.call(request: req, operation: :chat)).to include(:structured_output)
      end

      it 'not triggered when response_format type is :text (the default)' do
        req = build_request(response_format: { type: :text })
        expect(described_class.call(request: req, operation: :chat)).not_to include(:structured_output)
      end

      it 'not triggered when response_format schema is empty' do
        req = build_request(response_format: { type: :text, schema: {} })
        expect(described_class.call(request: req, operation: :chat)).not_to include(:structured_output)
      end
    end

    # -----------------------------------------------------------------------
    # Deduplication
    # -----------------------------------------------------------------------
    context 'deduplication' do
      it 'deduplicate :tools when triggered by both tools array and a tool_use block' do
        messages = [
          { role: :assistant, content: [{ type: :tool_use, id: 'tu_1', name: 'search', input: {} }] }
        ]
        req = build_request(tools: [{ name: 'search' }], messages: messages)
        result = described_class.call(request: req, operation: :chat)
        expect(result.count(:tools)).to eq(1)
      end

      it 'deduplicates :streaming when it is both the base cap and would otherwise appear twice' do
        # stream_chat base already includes :streaming; no shape trigger adds it again,
        # but normalize must not create duplicates if it were added a second time.
        req = build_request
        result = described_class.call(request: req, operation: :stream_chat)
        expect(result.count(:streaming)).to eq(1)
      end
    end

    # -----------------------------------------------------------------------
    # OpenAI Responses dialect: :responses must NOT be inferred
    # -----------------------------------------------------------------------
    context 'OpenAI Responses dialect' do
      # The canonical adapter must preserve N×N execution through ordinary chat/stream_chat
      # operations. The HTTP dialect is invisible to RequiredCapabilities; no routing path
      # may inject :responses from the body or headers.
      it 'never includes :responses for a chat request' do
        req = build_request(messages: [{ role: :user, content: 'hello' }])
        expect(described_class.call(request: req, operation: :chat)).not_to include(:responses)
      end

      it 'never includes :responses for a stream_chat request' do
        req = build_request(messages: [{ role: :user, content: 'hello' }], stream: true)
        expect(described_class.call(request: req, operation: :stream_chat)).not_to include(:responses)
      end

      it 'never includes :responses even with tools present' do
        req = build_request(tools: [{ name: 'code_interpreter' }])
        expect(described_class.call(request: req, operation: :chat)).not_to include(:responses)
      end
    end

    # -----------------------------------------------------------------------
    # Return value contract
    # -----------------------------------------------------------------------
    context 'return value contract' do
      it 'returns a frozen Array' do
        result = described_class.call(request: plain_request, operation: :chat)
        expect(result).to be_a(Array)
        expect(result).to be_frozen
      end

      it 'contains only canonical capability Symbols' do
        canonical = Legion::Extensions::Llm::Capabilities::CANONICAL
        all_caps_req = build_request(
          tools:           [{ name: 'search' }],
          thinking:        { enabled: true },
          response_format: { type: :json_schema },
          messages:        [
            { role: :user, content: [{ type: :image_url, image_url: { url: 'https://example.com/img.png' } }] }
          ]
        )
        result = described_class.call(request: all_caps_req, operation: :stream_chat)
        expect(result).to all(be_a(Symbol))
        result.each do |cap|
          expect(canonical).to include(cap), "#{cap.inspect} is not a canonical capability"
        end
      end
    end
  end
end
