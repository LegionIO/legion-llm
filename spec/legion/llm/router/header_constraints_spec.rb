# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/header_constraints'

RSpec.describe Legion::LLM::Router::HeaderConstraints do
  let(:snap_class) { Struct.new(:maximum_attempts, keyword_init: true) }
  let(:settings_snapshot) { snap_class.new(maximum_attempts: 5) }

  def call(headers)
    described_class.call(headers: headers, settings_snapshot: settings_snapshot)
  end

  it 'parses the canonical X-Legion-* headers' do
    v = call('X-Legion-Provider' => 'vLLM', 'X-Legion-Instance' => 'h200',
             'X-Legion-Model' => 'gemma4', 'X-Legion-Tier' => 'local', 'X-Legion-Max-Attempts' => '2')
    expect(v.provider).to eq('vllm')
    expect(v.instance_id).to eq('h200')
    expect(v.model).to eq('gemma4')
    expect(v.tier).to eq(:local)
    expect(v.maximum_attempts).to eq(2)
    expect(v).to be_frozen
  end

  it 'reads Rack env header names too' do
    v = call('HTTP_X_LEGION_MODEL' => 'gemma4')
    expect(v.model).to eq('gemma4')
  end

  it 'treats blank/absent as nil' do
    v = call('X-Legion-Provider' => '   ')
    expect(v.provider).to be_nil
    expect(v.model).to be_nil
    expect(v.maximum_attempts).to be_nil
  end

  it 'rejects comma-separated alternatives' do
    expect { call('X-Legion-Model' => 'a,b') }.to raise_error(Legion::LLM::Errors::InvalidHeader)
  end

  it 'validates tier against the Phase 1 taxonomy' do
    expect { call('X-Legion-Tier' => 'nonsense') }.to raise_error(Legion::LLM::Errors::InvalidHeader)
    expect(call('X-Legion-Tier' => 'frontier').tier).to eq(:frontier)
  end

  it 'validates max attempts as a positive integer bounded by the configured maximum' do
    expect { call('X-Legion-Max-Attempts' => '0') }.to raise_error(Legion::LLM::Errors::InvalidHeader)
    expect { call('X-Legion-Max-Attempts' => '6') }.to raise_error(Legion::LLM::Errors::InvalidHeader)
    expect { call('X-Legion-Max-Attempts' => 'x') }.to raise_error(Legion::LLM::Errors::InvalidHeader)
    expect(call('X-Legion-Max-Attempts' => '5').maximum_attempts).to eq(5)
  end

  it 'from_internal builds the same immutable value' do
    v = described_class.from_internal(provider: 'Anthropic', model: 'claude', settings_snapshot: settings_snapshot)
    expect(v.provider).to eq('anthropic')
    expect(v.model).to eq('claude')
    expect(v.tier).to be_nil
  end

  it 'nil headers yields an all-nil value' do
    v = described_class.call(headers: nil, settings_snapshot: settings_snapshot)
    expect(v.provider).to be_nil
    expect(v.maximum_attempts).to be_nil
  end

  # ---------------------------------------------------------------------------
  # Encoding normalization at the trust boundary
  # ---------------------------------------------------------------------------
  #
  # Puma 8 serves HTTP header values as ASCII-8BIT (BINARY) strings. Those
  # values become explicit routing pins; the frozen lex-llm inventory records
  # accept only valid UTF-8/US-ASCII, so a BINARY pin crashed Rejection
  # validation with an untyped ValidationError (HTTP 500). Pin values are
  # normalized to UTF-8 where they enter; genuinely invalid UTF-8 bytes are a
  # malformed trusted hint (Errors::InvalidHeader, HTTP 400).

  describe 'encoding normalization (Puma 8 ASCII-8BIT header values)' do
    it 'normalizes an ASCII-8BIT ASCII-only header value to UTF-8 with identical content' do
      raw = 'us.anthropic.claude-sonnet-4-6'.b
      expect(raw.encoding).to eq(Encoding::ASCII_8BIT)
      expect(raw.ascii_only?).to be(true)

      v = call('X-Legion-Model' => raw, 'X-Legion-Provider' => 'Bedrock'.b, 'X-Legion-Instance' => 'primary'.b)
      expect(v.model).to eq('us.anthropic.claude-sonnet-4-6')
      expect(v.model.encoding).to eq(Encoding::UTF_8)
      expect(v.provider).to eq('bedrock')
      expect(v.provider.encoding).to eq(Encoding::UTF_8)
      expect(v.instance_id).to eq('primary')
      expect(v.instance_id.encoding).to eq(Encoding::UTF_8)
    end

    it 'normalizes ASCII-8BIT values on the from_internal path (trusted routing hash)' do
      v = described_class.from_internal(
        model: 'gemma4'.b, instance_id: 'h200'.b,
        settings_snapshot: settings_snapshot
      )
      expect(v.model).to eq('gemma4')
      expect(v.model.encoding).to eq(Encoding::UTF_8)
      expect(v.instance_id).to eq('h200')
      expect(v.instance_id.encoding).to eq(Encoding::UTF_8)
    end

    it 'leaves valid UTF-8 values with identical content' do
      v = call('X-Legion-Model' => 'gemma4')
      expect(v.model).to eq('gemma4')
      expect(v.model.encoding).to eq(Encoding::UTF_8)
    end

    it 'raises InvalidHeader (typed 400), not ValidationError, for genuinely invalid UTF-8 bytes' do
      bad = "gemma4\xFF".b # 0xFF is never a valid UTF-8 leading byte
      expect(bad.encoding).to eq(Encoding::ASCII_8BIT)
      expect(bad.dup.force_encoding(Encoding::UTF_8).valid_encoding?).to be(false)

      expect { call('X-Legion-Model' => bad) }.to raise_error(Legion::LLM::Errors::InvalidHeader)
      expect do
        described_class.from_internal(model: bad, settings_snapshot: settings_snapshot)
      end.to raise_error(Legion::LLM::Errors::InvalidHeader)
    end
  end
end
