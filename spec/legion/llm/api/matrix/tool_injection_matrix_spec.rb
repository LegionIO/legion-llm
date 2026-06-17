# frozen_string_literal: true

# Regression encoding for the claude/vllm legionio_tool_injection cell.
#
# The live e2e cell sends a tool-less /v1/messages request asking
# "how many legionio tools do you have available?". The daemon must inject
# the registered LegionIO tool definitions into the upstream provider call —
# both the special pinned tools (legion_list_special_tools / legion_list_all_tools)
# and any registry-registered tools — so the model can either list them or
# call a discovery tool. When injection breaks, the model has no tools in its
# `tools:` slot and answers "There is no tool" (parroting the system_baseline).
#
# This spec captures the failure offline: it asserts that on a tool-less
# inbound request, FakeProvider.calls.first[:tools] contains the registered
# LegionIO tool. If injection drops out, this spec fails identically to the
# live cell.

require_relative 'matrix_helper'

RSpec.describe '[matrix] LegionIO tool injection — registered tools must reach the provider', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before do
    MatrixHelper.configure_for_fake!
    MatrixHelper.register_legion_tool!
  end

  after do
    MatrixHelper.unregister_legion_tool!
    MatrixHelper.restore_started_state!
  end

  shared_examples 'injects LegionIO tools into upstream provider call' do |route_name, payload_block|
    it "(#{route_name}) sends the registered LegionIO tool definitions to the provider" do
      FakeProvider.with_scenario(:text) do
        post payload_block[:path],
             Legion::JSON.dump(payload_block[:body]),
             'CONTENT_TYPE' => 'application/json'
      end

      expect(last_response.status).to eq(200), -> { "got #{last_response.status}: #{last_response.body[0, 200]}" }

      calls = FakeProvider.calls
      expect(calls).not_to be_empty
      first = calls.first
      tools = first[:tools]

      # Tools may surface as a Hash {name => definition} or an Array of
      # definitions depending on the provider seam — both shapes count.
      tool_names =
        case tools
        when Hash  then tools.keys.map(&:to_s)
        when Array then tools.filter_map { |t| (t[:name] || t['name']).to_s }
        else            []
        end

      expect(tool_names).not_to be_empty,
                                "tool injection dropped — provider received no tool definitions on #{route_name}"
      expect(tool_names).to include('fake_legion_echo'),
                            "registered LegionIO tool 'fake_legion_echo' missing from provider call (#{route_name}); got #{tool_names.inspect}"
    end
  end

  include_examples 'injects LegionIO tools into upstream provider call', '/v1/messages',
                   path: '/v1/messages',
                   body: {
                     model:      'fake-default',
                     max_tokens: 1024,
                     messages:   [{ role: 'user', content: 'how many legionio tools do you have available?' }]
                   }

  include_examples 'injects LegionIO tools into upstream provider call', '/v1/responses',
                   path: '/v1/responses',
                   body: {
                     model: 'fake-default',
                     input: 'how many legionio tools do you have available?'
                   }

  include_examples 'injects LegionIO tools into upstream provider call', '/v1/chat/completions',
                   path: '/v1/chat/completions',
                   body: {
                     model:    'fake-default',
                     messages: [{ role: 'user', content: 'how many legionio tools do you have available?' }]
                   }
end
