# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'
require 'legion/settings/extensions'

RSpec.describe 'Inference hot-path logging' do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :vllm, model: SSOT_TEST_MODEL }
    )
  end
  let(:executor) { Legion::LLM::Inference::Executor.new(request) }
  let(:output) { StringIO.new }
  let(:level) { Logger::INFO }
  let(:logger) { Logger.new(output, level: level) }

  before { allow(executor).to receive(:log).and_return(logger) }

  [Logger::INFO, Logger::DEBUG].each do |log_level|
    context "at #{Logger::SEV_LABEL[log_level]} level" do
      let(:level) { log_level }

      it 'retains pipeline timings while emitting the timing table only at DEBUG' do
        write_test_lane

        response = executor.call

        expect(response.message[:content]).to eq('test response')
        expect(response.timestamps[:step_timings]).to include(:provider_call, :total)
        timing_logs = output.string.lines.select { |line| line.include?('[pipeline][timing]') }
        if log_level == Logger::DEBUG
          expect(timing_logs.size).to eq(1)
          expect(timing_logs.first).to include('DEBUG', 'provider_call=', 'total=')
        else
          expect(timing_logs).to be_empty
        end
      end

      %i[execute_native_tool_loop execute_native_streaming_tool_loop].each do |method|
        it "avoids inspecting response text with DEBUG disabled in #{method}" do
          response = native_dispatch_result(content: 'large response ' * 1000)
          allow(executor).to receive(:dispatch_provider_request).and_return(response)
          inspections = 0
          trace = TracePoint.new(:c_call) do |event|
            inspections += 1 if event.method_id == :inspect && event.self.equal?(response.text)
          end

          result = trace.enable { executor.send(method) { |_chunk| nil } }

          expect(result).to equal(response)
          if log_level == Logger::DEBUG
            expect(inspections).to be_positive
            expect(output.string).to include('result_text_length=15000')
          else
            expect(inspections).to eq(0)
          end
        end
      end
    end
  end

  it 'discovers real registry tools without copying the registry just to log its count' do
    registry = Legion::Settings::Extensions
    registry.register_tool('logging_eager', description: 'Eager tool', deferred: false)
    registry.register_tool('logging_deferred', description: 'Deferred tool', deferred: true)
    original_count = registry.tool_count
    allow(registry).to receive(:tools).and_call_original

    executor.send(:discover_registry_tools)

    expect(executor.discovered_tools.map { |tool| tool[:name] }).to include('logging_eager')
    expect(executor.discovered_tools.map { |tool| tool[:name] }).not_to include('logging_deferred')
    expect(output.string).to include("settings_extensions_total=#{original_count}")
    expect(registry).to have_received(:tools).once
  ensure
    registry&.unregister_tool('logging_eager')
    registry&.unregister_tool('logging_deferred')
  end
end
