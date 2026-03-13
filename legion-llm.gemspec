# frozen_string_literal: true

require_relative 'lib/legion/llm/version'

Gem::Specification.new do |spec|
  spec.name = 'legion-llm'
  spec.version       = Legion::LLM::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']
  spec.summary       = 'LLM integration for the LegionIO framework via ruby_llm'
  spec.description   = 'Provides LLM capabilities (chat, embeddings, tool use, agents) to LegionIO extensions'
  spec.homepage      = 'https://github.com/LegionIO/legion-llm'
  spec.license       = 'Apache-2.0'
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.4'
  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.extra_rdoc_files = %w[README.md LICENSE CHANGELOG.md]
  spec.metadata = {
    'bug_tracker_uri'       => 'https://github.com/LegionIO/legion-llm/issues',
    'changelog_uri'         => 'https://github.com/LegionIO/legion-llm/blob/main/CHANGELOG.md',
    'documentation_uri'     => 'https://github.com/LegionIO/legion-llm',
    'homepage_uri'          => 'https://github.com/LegionIO/LegionIO',
    'source_code_uri'       => 'https://github.com/LegionIO/legion-llm',
    'wiki_uri'              => 'https://github.com/LegionIO/legion-llm/wiki',
    'rubygems_mfa_required' => 'true'
  }

  spec.add_dependency 'legion-logging'
  spec.add_dependency 'legion-settings'
  spec.add_dependency 'ruby_llm', '>= 1.0'
end
