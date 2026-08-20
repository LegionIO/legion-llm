# frozen_string_literal: true

# # frozen_string_literal: true
#
# # T7 temporary diagnostic probe — deletes itself. Verifies the fixed
# # reset! (atomic loader swap) closes the race: main runs the exact
# # per-example settings sequence 5000x while a worker reads Settings[:llm].
# # Pre-fix baseline for this probe: STRESS nil_reads=593386.
# require 'spec_helper'
#
# RSpec.describe 'T7 probe' do
#   it 'stress: worker reads Settings[:llm] while main resets+merges (fixed reset!)' do
#     nil_reads = 0
#     stop = Concurrent::AtomicBoolean.new(false)
#     worker = Thread.new do
#       until stop.value
#         v = Legion::Settings[:llm]
#         nil_reads += 1 if v.nil?
#       end
#     end
#
#     5000.times do
#       Legion::Settings.reset!
#       Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
#     end
#     stop.value = true
#     worker.join
#     warn "STRESS-FIXED nil_reads=#{nil_reads}"
#   end
# end
