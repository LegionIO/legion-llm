# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      # Admin endpoint for the live inventory store.
      # POST /api/llm/inventory/refresh — re-write lanes for a scope (or all lanes)
      # with updated weights from current settings. Intended for the operator FinOps
      # lever ("$1M expiring → bump weight, drain, drop") and for manual recovery
      # after a credential rotation that doesn't fire a settings observer (G28).
      module InventoryAdmin
        extend Legion::Logging::Helper

        def self.registered(app, **)
          log.debug('[llm][api][inventory_admin] registering inventory admin routes')

          app.post '/api/llm/inventory/refresh' do
            body_raw = request.body&.read
            body = if body_raw && !body_raw.empty?
                     Legion::JSON.load(body_raw)
                   else
                     {}
                   end
            scope = body[:scope] || {}
            if scope.empty?
              Legion::LLM::Inventory::SettingsObserver.rewrite_all_lanes!
            else
              path = [:extensions, :llm, scope[:provider]&.to_sym].compact
              Legion::LLM::Inventory::SettingsObserver.handle_change(path: path)
            end
            json_response(data: { refreshed: true, scope: scope })
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.api.inventory_admin.refresh')
            json_error('inventory_refresh_error', e.message, status_code: 500)
          end
        end
      end
    end
  end
end
