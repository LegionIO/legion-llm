# frozen_string_literal: true

module Legion
  module LLM
    module Settings
      # Default settings for the Legion::LLM::Routing namespace, matched to the
      # module nested path: a setting for Legion::LLM::Routing::Foo lives at
      # Settings::Router.foo. Each default is its own self.<key> method;
      # defaults aggregates them. Wired into Settings.default as routing: once
      # the settings.rb rewire lands.
      module Router
        extend Legion::Logging::Helper

        def self.body_model_hint_whitelist
          []
        end

        def self.body_model_hint_blacklist
          []
        end

        def self.model_passthrough_ids
          %w[copilot-utility-small]
        end

        def self.auto_routing_model_aliases
          %w[legionio auto copilot-utility-small]
        end

        def self.auto_routing_model_alias_metadata
          {
            'copilot-utility-small' => { owned_by: 'legionio' }
          }
        end

        def self.defaults
          {
            body_model_hint_whitelist:         body_model_hint_whitelist,
            body_model_hint_blacklist:         body_model_hint_blacklist,
            model_passthrough_ids:             model_passthrough_ids,
            auto_routing_model_aliases:        auto_routing_model_aliases,
            auto_routing_model_alias_metadata: auto_routing_model_alias_metadata
          }
        end
      end
    end
  end
end
