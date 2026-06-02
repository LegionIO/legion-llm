# frozen_string_literal: true

require 'open3'
require 'spec_helper'

RSpec.describe 'legion-llm load phase' do
  it 'loads shared settings when requiring legion/llm directly' do
    code = <<~RUBY
      require 'legion/llm'
      raise 'settings missing' unless defined?(Legion::Settings)
      raise 'llm defaults missing' unless Legion::Settings[:llm][:enabled] == true
      Legion::Settings[:llm][:default_model] = 'override-model'
      raise 'override missing' unless Legion::Settings[:llm][:default_model] == 'override-model'
    RUBY

    output, status = Open3.capture2e(Gem.ruby, '-Ilib', '-e', code, chdir: File.expand_path('../../..', __dir__))

    expect(status).to be_success, output
  end
end
