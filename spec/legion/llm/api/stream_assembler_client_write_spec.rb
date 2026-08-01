# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/stream_assembler'

# Root cause of the field restart-cascade: Puma::ConnectionError ("Socket timeout writing
# data") is a RuntimeError, NOT an IOError, so the StreamAssembler's historical
# `rescue IOError, Errno::EPIPE` guards let it ESCAPE the assembler and reach the executor,
# where it was misattributed to the upstream provider and tripped a healthy lane's circuit.
#
# These specs pin BOTH directions at the assembler boundary:
#   * A client-write failure (Puma::ConnectionError / EPIPE / ECONNRESET / IOError) is caught,
#     flips the assembler to closed, and (from push) surfaces as StreamClosed — the clean
#     cancellation the route already handles — never as a raw provider-looking error.
#   * A genuine daemon bug (a plain RuntimeError that is NOT a client-write) still PROPAGATES,
#     so it surfaces loudly instead of being masked as a disconnect.
# Puma::ConnectionError is a RuntimeError, NOT an IOError. Reproduced faithfully here since
# puma is not in this gem's bundle; classification matches by fully-qualified class name.
unless defined?(::Puma::ConnectionError)
  ::Object.const_set(:Puma, Module.new) unless defined?(::Puma)
  ::Puma.const_set(:ConnectionError, Class.new(RuntimeError))
end

# Emitter whose every callback raises the injected error, mimicking a write to a dead client
# socket (or a daemon bug) at on_start / on_text_delta / on_done time. Defined at file scope so
# the anonymous class isn't a describe-block constant (Lint/ConstantDefinitionInBlock).
class RaisingEmitter
  def initialize(error) = (@error = error)
  def method_missing(_name, *, **) = raise(@error)
  def respond_to_missing?(_name, _include_private = false) = true
end

# Client-write exception family. Puma::ConnectionError is the production culprit — a
# RuntimeError that the historical rescue IOError/EPIPE guards let escape raw.
module AssemblerClientWriteFixtures
  module_function

  def client_write
    {
      'Puma::ConnectionError' => -> { ::Puma::ConnectionError.new('Socket timeout writing data') },
      'Errno::EPIPE'          => -> { Errno::EPIPE.new('Broken pipe') },
      'Errno::ECONNRESET'     => -> { Errno::ECONNRESET.new('Connection reset by peer') },
      'IOError'               => -> { IOError.new('closed stream') }
    }
  end
end

RSpec.describe Legion::LLM::API::StreamAssembler, 'client-write vs daemon-bug handling' do
  def raising_emitter(error)
    RaisingEmitter.new(error)
  end

  def build_assembler(emitter)
    described_class.new(
      emitter:      emitter,
      request_id:   'msg_test',
      model:        'gemma-4-31b-it',
      initial_lane: { id: 'fleet:vllm:h200:inference:gemma-4-31b-it' }
    )
  end

  # Fixture verification: Puma::ConnectionError must be a RuntimeError, NOT an IOError —
  # otherwise the historical guards would already have caught it and there'd be no bug.
  it 'confirms Puma::ConnectionError is a RuntimeError, not an IOError (the ancestry gap)' do
    expect(::Puma::ConnectionError.ancestors).to include(RuntimeError)
    expect(::Puma::ConnectionError.ancestors).not_to include(IOError)
  end

  describe '#push (mid-stream client write)' do
    AssemblerClientWriteFixtures.client_write.each do |label, builder|
      it "absorbs #{label} into a clean disconnect (marks closed; next push raises StreamClosed)" do
        assembler = build_assembler(raising_emitter(instance_exec(&builder)))
        chunk = Legion::Extensions::Llm::Canonical::Chunk.text_delta(delta: 'hi', request_id: 'msg_test')

        # PRE-FIX: Puma::ConnectionError (a RuntimeError, not IOError) escaped guard/push RAW
        # and reached the executor, which misattributed it to the provider. POST-FIX it is
        # absorbed here as a client write and the assembler flips closed.
        expect { assembler.push(chunk) }.not_to raise_error
        expect(assembler).to be_closed

        # The already-closed assembler surfaces the disconnect as StreamClosed on the next push —
        # the clean cancellation the route rescues, never a provider-looking error.
        expect { assembler.push(chunk) }.to raise_error(described_class::StreamClosed)
      end
    end

    it 'PROPAGATES a genuine daemon bug (non-client-write RuntimeError) instead of masking it' do
      assembler = build_assembler(raising_emitter(RuntimeError.new('daemon bug: undefined behavior')))
      chunk = Legion::Extensions::Llm::Canonical::Chunk.text_delta(delta: 'hi', request_id: 'msg_test')

      expect { assembler.push(chunk) }.to raise_error(RuntimeError, /daemon bug/)
      expect(assembler).not_to be_closed
    end
  end

  describe '#finalize (end-of-stream client write)' do
    AssemblerClientWriteFixtures.client_write.each do |label, builder|
      it "swallows #{label} as a clean disconnect (marks closed, does not raise)" do
        assembler = build_assembler(raising_emitter(instance_exec(&builder)))
        response = Struct.new(:message, :tools, :stop, :tokens, :routing, keyword_init: true).new(
          message: { role: :assistant, content: 'done' }, tools: [], stop: { reason: :end_turn },
          tokens: { input_tokens: 1, output_tokens: 1 }, routing: { model: 'gemma-4-31b-it' }
        )

        expect { assembler.finalize(response) }.not_to raise_error
        expect(assembler).to be_closed
      end
    end

    it 'PROPAGATES a genuine daemon bug from finalize instead of masking it as a disconnect' do
      assembler = build_assembler(raising_emitter(RuntimeError.new('daemon bug in finalize')))
      response = Struct.new(:message, :tools, :stop, :tokens, :routing, keyword_init: true).new(
        message: { role: :assistant, content: 'done' }, tools: [], stop: { reason: :end_turn },
        tokens: { input_tokens: 1, output_tokens: 1 }, routing: { model: 'gemma-4-31b-it' }
      )

      expect { assembler.finalize(response) }.to raise_error(RuntimeError, /daemon bug/)
    end
  end
end
