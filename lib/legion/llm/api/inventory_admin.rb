# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      # Admin endpoint for the inventory.
      # POST /api/llm/inventory/refresh — operator lever ("$1M expiring →
      # bump weight, drain, drop") and manual recovery after a credential
      # rotation. The daemon holds no lane store and no weight engine:
      # each provider publisher recomputes write-time weights from current
      # settings on its own discovery cadence (lex-llm
      # Inventory::WeightReconciler) and re-publishes into the single
      # registry; the selector reads settings through its own generation.
      # The route reports that state honestly — it never claims to have
      # reweighted anything.
      module InventoryAdmin
        extend Legion::Logging::Helper

        REFRESH_NOTE = 'lane weights are recomputed by each provider publisher from current ' \
                       'settings on its discovery cadence (lex-llm WeightReconciler); the daemon ' \
                       'holds no lane store to reweight'

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
            log.info("[llm][api][inventory_admin] action=refresh scope=#{scope} result=publisher_driven")
            json_response(data: { refreshed: false, scope: scope, note: REFRESH_NOTE })
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.api.inventory_admin.refresh')
            json_error('inventory_refresh_error', e.message, status_code: 500)
          end
        end
      end
    end
  end
end
