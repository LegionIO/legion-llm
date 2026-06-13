# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'No legacy non-stateful fallback', :contract do
  it 'has no legacy non-stateful fallback helpers in production code' do
    files = Dir['lib/**/*.rb']
    body = files.to_h { |path| [path, File.read(path)] }
    forbidden = /try_fallback_or_raise|find_fallback_provider|fallback_local_providers\?/
    offenders = body.filter_map { |path, text| path if text.match?(forbidden) }
    expect(offenders).to be_empty,
      "Found legacy fallback helpers in: #{offenders.join(', ')}"
  end
end
