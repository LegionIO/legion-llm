# frozen_string_literal: true

require_relative 'lib/legion/llm/version'

Gem::Specification.new do |spec|
  spec.name = 'legion-llm'
  spec.version       = Legion::LLM::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']
  spec.summary       = 'LLM gateway: tiered routing, mid-stream failover, and context curation in one proxy'
  spec.description   = 'A proxy between AI clients and model backends. Requests translate once to a canonical form, ' \
                       'route to the cheapest capable tier (local, direct, fleet, cloud, frontier), and escalate on ' \
                       'failure with circuit breakers and mid-stream failover. A post-turn Curator bounds long agent ' \
                       'sessions (97.7% context reduction vs naive resend at 50+ turns, production-measured). Provider ' \
                       'adapters are separate lex-llm-* gems.'
  spec.homepage      = 'https://github.com/LegionIO/legion-llm'
  spec.license       = 'Apache-2.0'
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.4'
  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.extra_rdoc_files = %w[README.md LICENSE CHANGELOG.md]
  spec.metadata = {
    'bug_tracker_uri'       => 'https://github.com/LegionIO/legion-llm/issues',
    'changelog_uri'         => 'https://github.com/LegionIO/legion-llm/blob/main/CHANGELOG.md',
    'documentation_uri'     => 'https://github.com/LegionIO/legion-llm#readme',
    'homepage_uri'          => 'https://github.com/LegionIO/LegionIO',
    'source_code_uri'       => 'https://github.com/LegionIO/legion-llm',
    'wiki_uri'              => 'https://github.com/LegionIO/legion-llm/wiki',
    'rubygems_mfa_required' => 'true'
  }

  spec.add_dependency 'concurrent-ruby'
  spec.add_dependency 'event_stream_parser', '~> 1'
  spec.add_dependency 'faraday'
  spec.add_dependency 'legion-cache', '>= 1.4.2'
  spec.add_dependency 'legion-json', '>= 1.2.0'
  spec.add_dependency 'legion-logging', '>= 1.2.8'
  spec.add_dependency 'legion-settings', '>= 1.4.2'
  spec.add_dependency 'legion-transport', '>= 1.4.14'
  spec.add_dependency 'lex-knowledge'
  spec.add_dependency 'lex-llm', '>= 0.7.0'
  spec.add_dependency 'pdf-reader'
  spec.add_dependency 'sinatra-contrib', '>= 2.0'
  spec.add_dependency 'tzinfo', '>= 2.0'
end
