# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'legion/llm/skills/step_result'
require 'legion/llm/skills/skill_run_result'
require 'legion/llm/skills/errors'
require 'legion/llm/skills/base'
require 'legion/llm/skills/registry'
require 'legion/llm/skills/disk_loader'

RSpec.describe Legion::LLM::Skills::DiskLoader do
  before { Legion::LLM::Skills::Registry.reset! }

  describe '.load_from_directories' do
    it 'skips directories that do not exist' do
      expect(described_class.load_from_directories(['/nonexistent/path'])).to eq(0)
    end
  end

  describe '.load_md_skill' do
    it 'creates a skill class from YAML frontmatter + body and registers it' do
      content = <<~MD
        ---
        name: my-disk-skill
        namespace: disk
        description: A disk skill
        trigger: on_demand
        ---
        This is the skill content.
      MD

      described_class.load_md_skill('/fake/path.md', content: content)
      skill = Legion::LLM::Skills::Registry.find('disk:my-disk-skill')
      expect(skill).not_to be_nil
      expect(skill.skill_name).to eq('my-disk-skill')
      expect(skill.namespace).to eq('disk')
    end
  end

  describe '.parse_frontmatter' do
    it 'extracts YAML frontmatter and body' do
      text = "---\nname: test\n---\nbody text"
      meta, body = described_class.parse_frontmatter(text)
      expect(meta[:name]).to eq('test')
      expect(body).to eq('body text')
    end

    it 'returns empty hash and full text when no frontmatter' do
      meta, body = described_class.parse_frontmatter('just markdown')
      expect(meta).to eq({})
      expect(body).to eq('just markdown')
    end
  end
end
