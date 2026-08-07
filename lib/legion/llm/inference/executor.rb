# frozen_string_literal: true

require 'concurrent'
require 'faraday'

require_relative '../publisher_identity'
require_relative '../tools/special'
require_relative 'native_tool_loop'
require_relative 'route_attempts'
require_relative 'executor/routing'
require_relative 'executor/escalation'
require_relative 'executor/context_window'
require_relative 'executor/tool_injection'

module Legion
  module LLM
    module Inference
      class Executor
        include Legion::Logging::Helper
        include NativeToolLoop
        include RouteAttempts
        include Routing
        include Escalation
        include ContextWindow
        include ToolInjection
        include Steps::Logging
        include Steps::Rbac
        include Steps::Classification
        include Steps::Billing
        include Steps::GaiaAdvisory
        include Steps::PostResponse
        include Steps::RagContext

        attr_reader :request, :profile, :timeline, :tracing, :enrichments,
                    :audit, :warnings, :discovered_tools, :confidence_score
        attr_accessor :tool_event_handler

        def context_accounting
          @context_accounting ||= ContextAccounting.empty
        end

        include Steps::TriggerMatch
        include Steps::SkillInjector
        include Steps::ToolDiscovery
        include Steps::ToolCalls
        include Steps::KnowledgeCapture
        include Steps::ConfidenceScoring
        include Steps::TokenBudget
        include Steps::PromptCache
        include Steps::Debate
        include Steps::Metering
        include Steps::StickyRunners
        include Steps::ToolHistory
        include Steps::StickyPersist
        include Steps::GutCheck

        PRE_PROVIDER_STEPS = %i[
          tracing_init idempotency conversation_uuid context_load
          rbac classification billing gaia_advisory tier_assignment rag_context
          trigger_match sticky_runners skill_injector tool_history_inject tool_discovery
          routing request_normalization token_budget
        ].freeze

        POST_PROVIDER_STEPS = %i[
          response_normalization post_response gut_check metering debate confidence_scoring
          tool_calls sticky_persist
          context_store knowledge_capture response_return
        ].freeze

        STEPS = (PRE_PROVIDER_STEPS + %i[provider_call] + POST_PROVIDER_STEPS).freeze

        ASYNC_SAFE_STEPS = %i[post_response knowledge_capture].freeze

        THINKING_TAG_PAIRS = [
          ['<thinking>', '</thinking>'],
          ['<think>',    '</think>'],
          ['<thought>',  '</thought>']
        ].freeze

        CONFIG_ERROR_PATTERNS = [
          /AccessDeniedException/,
          /InvalidModel/i,
          /model.*not found/i,
          /not authorized/i,
          /AWS Marketplace/i
        ].freeze

        REQUEST_PAYLOAD_ERROR_PATTERNS = [
          /input_schema/i,
          /tools\.\d+/,
          /messages\.\d+/,
          /Field required/i,
          /ValidationException/
        ].freeze

        CONTEXT_OVERFLOW_ERROR_PATTERNS = [
          /maximum context length/i,
          /context length.*input_tokens/i,
          /prompt contains at least \d+ input tokens/i
        ].freeze

        ToolResultEvent = Struct.new(:result, :tool_call_id, :tool_name, :started_at, :status, keyword_init: true)

        ASYNC_THREAD_POOL = Concurrent::FixedThreadPool.new(4, fallback_policy: :caller_runs)

        def initialize(request)
          @request = request
          @profile = Profile.derive(request.caller)
          @timeline = Timeline.new
          @tracing = nil
          @enrichments = {}
          @audit = {}
          @warnings = []
          @timestamps = { received: Time.now }
          @raw_response = nil
          @exchange_id = nil
          @discovered_tools = []
          @triggered_tools = []
          @resolved_provider = nil
          @resolved_instance = nil
          @resolved_model = nil
          @resolved_tier = nil
          @resolved_offering_id = nil
          @resolved_offering_metadata = {}
          @confidence_score = nil
          @escalation_history = []
          @route_attempts = []
          @current_escalation_context = nil
          @proactive_tier_assignment = nil
          @tool_event_handler = nil
          @sticky_turn_snapshot = nil
          @pending_tool_history = Concurrent::Array.new
          @pending_tool_history_mutex = Mutex.new
          @deferred_tool_audits = []
          @injected_tool_map = {}
          @native_tool_source_map = {}
          @freshly_triggered_keys = []
          @applied_signals = {
            advisory_id:            nil,
            behavioral_synapse_ids: [],
            trace_ids:              [],
            advisory_types:         [],
            envelope_keys:          [],
            prediction_id:          nil,
            response_stats:         {}
          }
          @context_accounting = ContextAccounting.empty
        end

        def call
          set_log_context
          Thread.current[:legion_llm_in_pipeline] = true
          log.debug "[llm][executor] action=call request_id=#{@request.id} profile=#{@profile}"
          execute_steps
          build_response
        ensure
          Thread.current[:legion_llm_in_pipeline] = nil
          clear_log_context
        end

        def call_stream(stream_observer: nil, &block)
          @stream_observer = stream_observer
          return call unless block

          set_log_context
          Thread.current[:legion_llm_in_pipeline] = true
          log.debug "[llm][executor] action=call_stream request_id=#{@request.id} profile=#{@profile}"
          execute_pre_provider_steps
          step_provider_call_stream(&block)
          execute_post_provider_steps
          build_response
        ensure
          @stream_observer = nil
          Thread.current[:legion_llm_in_pipeline] = nil
          clear_log_context
        end

        # N×N: Delegates to the canonical execution path.
        # The API namespace translator has already parsed the Responses API format
        # into canonical form. The provider adapter decides how to wire canonical
        # requests internally — the executor is format-agnostic.
        def call_responses(stream: false, stream_observer: nil, **, &block)
          @stream_observer = stream_observer
          set_log_context
          Thread.current[:legion_llm_in_pipeline] = true
          log.debug "[llm][executor] action=call_responses->canonical request_id=#{@request.id} profile=#{@profile} stream=#{stream}"

          execute_pre_provider_steps
          if stream && block
            step_provider_call_stream(&block)
          else
            step_provider_call
          end
          execute_post_provider_steps
          build_response
        ensure
          Thread.current[:legion_llm_in_pipeline] = nil
          @stream_observer = nil
          clear_log_context
        end

        private

        def set_log_context
          Thread.current[:legion_log_request_id] = @request.id
          Thread.current[:legion_log_conv_id] = @request.conversation_id
        end

        def clear_log_context
          Thread.current[:legion_log_request_id] = nil
          Thread.current[:legion_log_conv_id] = nil
          Thread.current[:legion_log_exchange_id] = nil
          Thread.current[:legion_log_chain_id] = nil
        end

        def registry_tool_limit
          return nil unless local_provider?

          raw_limit = Legion::Settings.dig(:llm, :tools, :trigger, :local_tool_limit)
          limit = raw_limit.to_i
          limit.positive? ? limit : nil
        end

        def execute_steps
          executed = 0
          skipped = 0
          pipeline_start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          step_timings = []
          @step_timing_hash = {}
          STEPS.each do |step|
            if Profile.skip?(@profile, step)
              skipped += 1
              next
            end

            t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            execute_step(step) { send(:"step_#{step}") }
            elapsed_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - t0) * 1000).round
            step_timings << "#{step}=#{elapsed_ms}ms"
            @step_timing_hash[step] = elapsed_ms
            executed += 1
          end
          total_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - pipeline_start) * 1000).round
          @step_timing_hash[:total] = total_ms
          @timestamps[:step_timings] = @step_timing_hash
          log.warn("[pipeline][timing] request_id=#{@request.id} conversation_id=#{@request.conversation_id} " \
                   "provider=#{@resolved_provider} model=#{@resolved_model} profile=#{@profile} " \
                   "total=#{total_ms}ms executed=#{executed} skipped=#{skipped} #{step_timings.join(' ')}")
          annotate_top_level_span(steps_executed: executed, steps_skipped: skipped)
        end

        def step_tracing_init
          log.debug "[llm][executor] action=step_tracing_init existing=#{!@request.tracing.nil?}"
          @tracing = Tracing.init(existing: @request.tracing)
          @timeline.record(
            category: :internal, key: 'tracing:init',
            direction: :internal, detail: 'trace initialized',
            from: 'pipeline', to: 'pipeline'
          )
        end

        def step_idempotency; end

        def step_conversation_uuid
          if @request.conversation_id
            Thread.current[:legion_log_conv_id] = @request.conversation_id
            log.debug "[llm][executor] action=step_conversation_uuid existing=#{@request.conversation_id}"
            return
          end

          new_id = "conv_#{SecureRandom.hex(8)}"
          @request = @request.with(conversation_id: new_id)
          Thread.current[:legion_log_conv_id] = new_id
          log.debug "[llm][executor] action=step_conversation_uuid generated=#{new_id}"
        end

        def step_context_load
          conv_id = @request.conversation_id
          unless conv_id
            log.debug '[llm][executor] action=step_context_load skipped=no_conversation_id'
            @context_accounting[:component_status][:context_load] = :observed
            return
          end

          history = Conversation.messages(conv_id)
          if history.empty?
            log.debug "[llm][executor] action=step_context_load conversation_id=#{conv_id} history=empty"
            @context_accounting[:component_status][:context_load] = :observed
            return
          end
          log.debug "[llm][executor] action=step_context_load conversation_id=#{conv_id} history_size=#{history.size}"

          loaded_tokens = ContextAccounting.estimate_message_tokens(history)
          @context_accounting[:tokens][:loaded_history_estimated_tokens] = loaded_tokens
          @context_accounting[:counts][:loaded_history_message_count] = history.size
          @context_accounting[:component_status][:context_load] = :observed
          @context_accounting[:events] << ContextAccounting.event(
            event_type:    :context_load,
            component:     :conversation_history,
            before_tokens: 0,
            after_tokens:  loaded_tokens,
            before_count:  0,
            after_count:   history.size
          )

          curator = Context::Curator.new(conversation_id: conv_id)
          curated = curator.curated_messages

          history = if curated && !curated.empty?
                      curated_tokens = ContextAccounting.estimate_message_tokens(curated)
                      @context_accounting[:tokens][:curated_history_estimated_tokens] = curated_tokens
                      @context_accounting[:tokens][:curation_saved_estimated_tokens] = [loaded_tokens - curated_tokens, 0].max
                      @context_accounting[:counts][:curated_history_message_count] = curated.size
                      @context_accounting[:component_status][:curation] = :observed
                      @context_accounting[:events] << ContextAccounting.event(
                        event_type:    :curation_applied,
                        component:     :curated_history,
                        before_tokens: loaded_tokens,
                        after_tokens:  curated_tokens,
                        before_count:  history.size,
                        after_count:   curated.size
                      )
                      @timeline.record(
                        category: :internal, key: 'context:curated',
                        direction: :internal, detail: "curated #{curated.size} of #{history.size} messages",
                        from: 'context_curator', to: 'pipeline'
                      )
                      curated
                    else
                      @context_accounting[:component_status][:curation] = :observed
                      maybe_compact_history(conv_id, history)
                    end

          before_archive_tokens = ContextAccounting.estimate_message_tokens(history)
          archived_history = curator.drop_and_archive(history, conversation_id: conv_id)
          if archived_history.size < history.size
            after_archive_tokens = ContextAccounting.estimate_message_tokens(archived_history)
            archived_tokens = [before_archive_tokens - after_archive_tokens, 0].max
            @context_accounting[:tokens][:archived_history_estimated_tokens] = archived_tokens
            @context_accounting[:tokens][:archive_saved_estimated_tokens] = archived_tokens
            @context_accounting[:counts][:archived_history_message_count] = history.size - archived_history.size
            @context_accounting[:component_status][:archive] = :observed
            @context_accounting[:events] << ContextAccounting.event(
              event_type:    :archive_applied,
              component:     :archived_history,
              before_tokens: before_archive_tokens,
              after_tokens:  after_archive_tokens,
              before_count:  history.size,
              after_count:   archived_history.size
            )
            @timeline.record(
              category: :internal, key: 'context:archived',
              direction: :outbound,
              detail: "archived #{history.size - archived_history.size} prior messages to Apollo",
              from: 'context_curator', to: 'apollo'
            )
            Conversation.replace(conv_id, archived_history)
            history = archived_history
          else
            @context_accounting[:component_status][:archive] = :observed
          end

          # Kill the history double-send: a client-managed client (e.g. Claude
          # Code) resends the full conversation in @request.messages every turn,
          # and those go on the wire as structured messages. Injecting the same
          # turns AGAIN as "Prior conversation history" system text (via
          # EnrichmentInjector) would send them twice — real tokens, real cost,
          # real context pressure. Only inject the prior turns the client did NOT
          # resend: empty for a fully client-managed turn, the whole stored prefix
          # for a server-managed client.
          history = reject_client_resent_history(history)
          @enrichments['context:conversation_history'] = history
          @timeline.record(
            category: :internal, key: 'context:loaded',
            direction: :internal, detail: "loaded #{history.size} prior messages",
            from: 'conversation_store', to: 'pipeline'
          )
        end

        # Drop stored-history messages the client already re-sent in
        # @request.messages, matched by (role, content-text) fingerprint. Prevents
        # the same turns reaching the provider twice (structured messages +
        # injected system text). See step_context_load.
        def reject_client_resent_history(history)
          resent = Array(@request.messages).to_set { |m| history_dedup_key(m) }
          Array(history).reject { |m| resent.include?(history_dedup_key(m)) }
        end

        def history_dedup_key(msg)
          role = (msg[:role] || msg['role']).to_s
          content = msg.is_a?(Hash) ? (msg[:content] || msg['content']) : msg
          [role, ContextAccounting.content_text(content).to_s.strip]
        end

        def maybe_compact_history(conv_id, history)
          # Guard against recursive compaction: if this thread is already compacting,
          # skip to prevent infinite loops when compressor calls back into chat_direct
          return history if Thread.current[:legion_compacting]

          conv_settings = Legion::Settings[:llm][:conversation]
          return history unless conv_settings[:auto_compact]

          threshold = conv_settings[:summarize_threshold]
          target_tokens = conv_settings[:target_tokens]
          preserve_recent = conv_settings[:preserve_recent]

          estimated = Context::Compressor.estimate_tokens(history)
          return history unless estimated >= threshold

          Thread.current[:legion_compacting] = true
          begin
            compact = Context::Compressor.auto_compact(
              history,
              target_tokens:   target_tokens,
              preserve_recent: preserve_recent
            )

            Conversation.replace(conv_id, compact)

            @timeline.record(
              category: :internal, key: 'context:compacted',
              direction: :internal,
              detail: "compacted #{history.size} messages (#{estimated} est. tokens) -> #{compact.size}",
              from: 'compressor', to: 'pipeline'
            )

            compact
          ensure
            Thread.current[:legion_compacting] = nil
          end
        end

        def native_assistant_tool_message(result, tool_calls)
          content = result.respond_to?(:text) ? result.text : result[:result]
          { role: :assistant, content: content.to_s, tool_calls: tool_calls }
        end

        def native_tool_result_message(tool_call, dispatch_result)
          {
            role:         :tool,
            content:      native_tool_result_content(dispatch_result),
            tool_call_id: tool_call[:id],
            name:         tool_call[:name]
          }.compact
        end

        def dispatch_native_tool_call(tool_call, round)
          normalized_call = normalize_native_tool_call(tool_call)
          source = find_tool_source(normalized_call[:name])
          log.debug "[llm][executor] action=dispatch_native_tool_call round=#{round} tool=#{normalized_call[:name]} source_type=#{source[:type]}"
          emit_tool_call_event(normalized_call, round, source: source)
          result = ToolDispatcher.dispatch(
            tool_call:   normalized_call,
            source:      source,
            exchange_id: Tracing.exchange_id
          )
          if result[:status] == :error
            err_detail = Legion::LLM::Tools::Dispatcher.error_log_detail(result)
            log.warn "[llm][native_tool_loop] action=tool_call_failed round=#{round} " \
                     "tool=#{normalized_call[:name]} source_type=#{source[:type]} error=#{err_detail}"
          else
            log.info "[llm][native_tool_loop] action=tool_result_received round=#{round} " \
                     "tool=#{normalized_call[:name]} status=#{result[:status]} duration_ms=#{result[:duration_ms]}"
          end
          emit_tool_result_event(
            ToolResultEvent.new(
              result:       native_tool_result_content(result),
              tool_call_id: normalized_call[:id],
              tool_name:    normalized_call[:name],
              started_at:   Thread.current[:legion_current_tool_started_at],
              status:       result[:status] || result['status']
            )
          )
          result
        ensure
          Thread.current[:legion_current_tool_call_id] = nil
          Thread.current[:legion_current_tool_name] = nil
          Thread.current[:legion_current_tool_started_at] = nil
          Thread.current[:legion_current_tool_history_index] = nil
        end

        def normalize_native_tool_call(tool_call)
          normalized = if tool_call.respond_to?(:transform_keys)
                         tool_call.transform_keys(&:to_sym)
                       elsif tool_call.respond_to?(:name)
                         {
                           id:        tool_call.respond_to?(:id) ? tool_call.id : nil,
                           name:      tool_call.name,
                           arguments: tool_call.respond_to?(:arguments) ? tool_call.arguments : {}
                         }
                       else
                         {}
                       end
          normalized[:arguments] = normalize_tool_arguments(normalized[:arguments])
          normalized[:id] ||= "call_#{SecureRandom.hex(12)}"
          normalized
        end

        def native_tool_result_content(result)
          status = result[:status] || result['status']
          if status.respond_to?(:to_sym) && status.to_sym == :error
            raw = Legion::LLM::Tools::Dispatcher.error_log_detail(result)
            return raw unless raw.to_s.empty?
          end

          raw = result[:result] || result[:content] || result[:error] ||
                result['result'] || result['content'] || result['error']
          raw.is_a?(String) ? raw : Legion::JSON.dump(raw || {})
        end

        def execute_pre_provider_steps
          log.debug "[llm][executor] action=pre_provider_steps.enter step_count=#{PRE_PROVIDER_STEPS.size} profile=#{@profile}"
          skipped = []
          PRE_PROVIDER_STEPS.each do |step|
            if Profile.skip?(@profile, step)
              skipped << step
              next
            end

            execute_step(step) { send(:"step_#{step}") }
          end
          if skipped.any?
            log.debug "[llm][executor] action=pre_provider_steps.complete executed=#{PRE_PROVIDER_STEPS.size - skipped.size} skipped=#{skipped.size} skipped_steps=#{skipped.join(',')}"
          end
          log.debug '[llm][executor] action=pre_provider_steps.complete' if skipped.empty?
        end

        def execute_post_provider_steps
          async = async_post_enabled?
          log.debug "[llm][executor] action=post_provider_steps.enter async=#{async} step_count=#{POST_PROVIDER_STEPS.size} profile=#{@profile}"
          if async
            execute_post_provider_steps_mixed
          else
            skipped = []
            POST_PROVIDER_STEPS.each do |step|
              if Profile.skip?(@profile, step)
                skipped << step
                next
              end

              execute_step(step) { send(:"step_#{step}") }
            end
            if skipped.any?
              log.debug "[llm][executor] action=post_provider_steps.complete executed=#{POST_PROVIDER_STEPS.size - skipped.size} skipped=#{skipped.size} skipped_steps=#{skipped.join(',')}"
            else
              log.debug '[llm][executor] action=post_provider_steps.complete'
            end
          end
        end

        def execute_post_provider_steps_mixed
          POST_PROVIDER_STEPS.each do |step|
            next if Profile.skip?(@profile, step)
            next if ASYNC_SAFE_STEPS.include?(step)

            execute_step(step) { send(:"step_#{step}") }
          end

          async_steps = POST_PROVIDER_STEPS.select { |s| ASYNC_SAFE_STEPS.include?(s) }
          return if async_steps.empty?

          # Snapshot timeline and warnings before firing the async thread so that
          # build_response (called on the main thread immediately after) reads a
          # consistent, immutable view rather than racing with async writes.
          @_response_timeline_snapshot = @timeline.events.dup.freeze
          @_response_warnings_snapshot = @warnings.dup.freeze
          @_response_participants_snapshot = @timeline.participants.dup.freeze

          profile = @profile
          ASYNC_THREAD_POOL.post do
            async_steps.each do |step|
              next if Profile.skip?(profile, step)

              send(:"step_#{step}")
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.async_post_steps', steps: async_steps)
          end
        end

        private :execute_post_provider_steps_mixed

        def async_post_enabled?
          Legion::Settings[:llm][:pipeline_async_post_steps] == true
        end

        private :async_post_enabled?

        def normalize_message_content(content)
          return content if content.nil? || content.is_a?(String)
          return content unless content.is_a?(Array)

          text_parts = content.filter_map do |b|
            next unless (b[:type] || b['type']).to_s == 'text'

            b[:text] || b['text']
          end
          text_parts.empty? ? nil : text_parts.join("\n\n")
        end

        def emit_tool_call_event(tool_call, round, source: nil)
          tc_id   = tool_call_field(tool_call, :id)
          tc_name = tool_call_field(tool_call, :name)
          tc_args = tool_call_field(tool_call, :arguments)
          started_at = Time.now

          typed_call = Types::ToolCall.build(
            id: tc_id, name: tc_name, arguments: tc_args,
            source: source,
            exchange_id: @exchange_id, started_at: started_at
          )

          log.debug("[pipeline][tool-call] action=emit round=#{round} id=#{tc_id} tool=#{tc_name}")
          log.info("[pipeline][tool-call] round=#{round} id=#{tc_id} tool=#{tc_name}")

          @pending_tool_history_mutex.synchronize do
            pending_index = @pending_tool_history.size
            @pending_tool_history << {
              tool_call_id:  tc_id,
              pending_index: pending_index,
              tool_name:     tc_name,
              args:          tc_args,
              result:        nil,
              error:         false,
              runner_key:    nil,
              typed_call:    typed_call
            }
            Thread.current[:legion_current_tool_history_index] = pending_index
          end

          Thread.current[:legion_current_tool_call_id] = tc_id
          Thread.current[:legion_current_tool_name] = tc_name
          Thread.current[:legion_current_tool_started_at] = started_at

          @tool_event_handler&.call(
            type: :tool_call, tool_call_id: tc_id, tool_name: tc_name,
            arguments: tc_args, round: round, started_at: started_at
          )
        end

        def emit_tool_result_event(tool_result)
          tc_id      = tool_result.respond_to?(:tool_call_id) ? tool_result.tool_call_id : Thread.current[:legion_current_tool_call_id]
          tc_name    = tool_result.respond_to?(:tool_name)    ? tool_result.tool_name    : Thread.current[:legion_current_tool_name]
          started_at = tool_result.respond_to?(:started_at)   ? tool_result.started_at   : Thread.current[:legion_current_tool_started_at]
          finished_at = Time.now
          raw = tool_result.respond_to?(:result) ? tool_result.result : tool_result
          status = tool_result.respond_to?(:status) ? tool_result.status : nil
          duration_ms = started_at ? ((finished_at - started_at) * 1000).round : nil

          result_str = (raw.is_a?(String) ? raw : raw.to_s)
          result_str = result_str.encode('UTF-8', invalid: :replace, undef: :replace, replace: '�') unless result_str.valid_encoding?
          result_str = result_str.delete("\x00")
          is_error = status.to_s == 'error' || (raw.is_a?(Hash) && (raw[:error] || raw['error']) ? true : false)

          @pending_tool_history_mutex.synchronize do
            entry = @pending_tool_history.find { |e| e[:tool_call_id] == tc_id && e[:result].nil? }
            entry ||= @pending_tool_history[Thread.current[:legion_current_tool_history_index]]
            if entry
              entry[:result] = result_str.is_a?(String) ? result_str : result_str.to_s
              entry[:error]  = is_error
              if entry[:typed_call]
                entry[:typed_call] = entry[:typed_call].with_result(
                  result:      result_str[0, 4096],
                  status:      is_error ? :error : :success,
                  duration_ms: duration_ms,
                  finished_at: finished_at
                )
              end
            end
          end

          log.debug("[pipeline][tool-result] action=emit id=#{tc_id} tool=#{tc_name} status=#{is_error ? :error : :success} duration_ms=#{duration_ms}")
          log.info("[pipeline][tool-result] id=#{tc_id} tool=#{tc_name} duration_ms=#{duration_ms}")

          @tool_event_handler&.call(
            type: :tool_result, tool_call_id: tc_id, tool_name: tc_name,
            result: result_str[0, 4096], result_size: result_str.bytesize, status: is_error ? :error : :success,
            started_at: started_at, finished_at: finished_at, duration_ms: duration_ms
          )

          publish_tool_audit(tc_id, tc_name, result_str, is_error, duration_ms, started_at, finished_at)
        end

        def publish_tool_audit(tc_id, tc_name, result_str, is_error, duration_ms, started_at, finished_at)
          @deferred_tool_audits << {
            tc_id: tc_id, tc_name: tc_name, result_str: result_str,
            is_error: is_error, duration_ms: duration_ms,
            started_at: started_at, finished_at: finished_at
          }
        end

        def flush_deferred_tool_audits
          return if @deferred_tool_audits.empty?

          audits = @deferred_tool_audits.dup
          @deferred_tool_audits.clear

          request_id      = @request.id
          conversation_id = @request.conversation_id
          exchange_id     = @exchange_id
          caller_data     = @request.caller
          classification  = @request.classification
          tracing         = @tracing

          Concurrent::Promises.future do
            audits.each do |audit|
              event = {
                request_id:      request_id,
                conversation_id: conversation_id,
                exchange_id:     exchange_id,
                tool_name:       audit[:tc_name],
                tool_call:       {
                  id:          audit[:tc_id],
                  name:        audit[:tc_name],
                  status:      audit[:is_error] ? :error : :success,
                  duration_ms: audit[:duration_ms],
                  started_at:  audit[:started_at],
                  finished_at: audit[:finished_at]
                },
                result:          audit[:result_str][0, 4096],
                caller:          caller_data,
                classification:  classification,
                tracing:         tracing,
                timestamp:       audit[:finished_at],
                request_type:    'tool'
              }
              Legion::LLM::Audit.emit_tools(event)
            rescue StandardError => e
              Legion::Logging.log.warn("[llm][pipeline] publish_tool_audit failed tool=#{audit[:tc_name]}: #{e.message} — spooling")
              spool_failed_tool_audit(event)
            end
          end
        end

        def spool_failed_tool_audit(event)
          spoolable = (event || {}).merge(event_type: 'tool_audit', spooled_at: Time.now.iso8601)
          Legion::LLM::Metering.send(:spool_event, spoolable)
        rescue StandardError => e
          Legion::Logging.log.warn("[llm][pipeline] spool_failed_tool_audit failed: #{e.message}")
        end

        def tool_call_field(tool_call, field)
          return tool_call.public_send(field) if tool_call.respond_to?(field)

          tool_call[field]
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.tool_call_field', field: field)
          nil
        end

        def execute_step(name, &block)
          started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          log_step_debug(name, :enter)
          unless pipeline_spans_enabled?
            begin
              result = block.call
              log_step_debug(name, :complete, duration_ms: elapsed_monotonic_ms(started_at))
              return result
            rescue StandardError => e
              log_step_info(name, :failed, error_class: e.class.name)
              raise
            end
          end

          block_called = false
          begin
            result = Legion::Telemetry.with_span("pipeline.#{name}", kind: :internal) do |span|
              block_called = true
              step_result = block.call
              annotate_span(span, name)
              step_result
            end
            log_step_debug(name, :complete, duration_ms: elapsed_monotonic_ms(started_at))
            result
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.with_step_span', step: name, block_called: block_called)
            log_step_info(name, :failed, error_class: e.class.name)
            raise if block_called

            fallback_result = block.call
            log_step_debug(name, :complete_after_span_failure, duration_ms: elapsed_monotonic_ms(started_at))
            fallback_result
          end
        end

        def elapsed_monotonic_ms(started_at)
          ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at) * 1000).round
        end

        def telemetry_enabled?
          !!(defined?(Legion::Telemetry) &&
            Legion::Telemetry.respond_to?(:enabled?) &&
            Legion::Telemetry.enabled?)
        end

        def pipeline_spans_enabled?
          return false unless telemetry_enabled?

          Legion::Settings[:llm][:telemetry][:pipeline_spans] != false
        end

        def annotate_span(span, step_name)
          return unless span.respond_to?(:set_attribute)

          attrs = Steps::SpanAnnotator.attributes_for(step_name, audit: @audit, enrichments: @enrichments)
          attrs.each { |key, val| span.set_attribute(key, val) unless val.nil? }
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.annotate_span', step: step_name)
          nil
        end

        def annotate_top_level_span(steps_executed:, steps_skipped:)
          return unless telemetry_enabled?
          return unless Legion::Telemetry.respond_to?(:current_span)

          span = Legion::Telemetry.current_span
          return unless span.respond_to?(:set_attribute)

          span.set_attribute('legion.pipeline.steps_executed', steps_executed)
          span.set_attribute('legion.pipeline.steps_skipped', steps_skipped)

          cost_entry = @audit[:'billing:budget_check'] || @audit[:'provider:response']
          if cost_entry.is_a?(Hash) && (cost = cost_entry.dig(:data, :estimated_cost_usd) || cost_entry[:estimated_cost_usd])
            span.set_attribute('gen_ai.usage.cost_usd', cost)
          end

          routing_entry = @audit[:'routing:provider_selection']
          if routing_entry.is_a?(Hash) && (data = routing_entry[:data])
            span.set_attribute('routing.strategy', data[:strategy].to_s) if data[:strategy]
            span.set_attribute('routing.tier', data[:tier].to_s) if data[:tier]
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.annotate_top_level_span')
          nil
        end

        def step_response_normalization
          # Normalize enrichment keys to consistent string "source:type" format
          normalized = {}
          @enrichments.each do |key, value|
            normalized[key.to_s] = value
          end
          @enrichments = normalized
        end

        def step_metering
          @extracted_tokens ||= extract_tokens
          input_tokens  = @extracted_tokens.respond_to?(:input_tokens)  ? @extracted_tokens.input_tokens.to_i  : 0
          output_tokens = @extracted_tokens.respond_to?(:output_tokens) ? @extracted_tokens.output_tokens.to_i : 0
          tier = @audit.dig(:'routing:provider_selection', :data, :tier)
          latency_ms = if @timestamps[:provider_start] && @timestamps[:provider_end]
                         ((@timestamps[:provider_end] - @timestamps[:provider_start]) * 1000).round
                       else
                         0
                       end
          wall_clock_ms = if @timestamps[:received]
                            ((Time.now - @timestamps[:received]) * 1000).round
                          else
                            0
                          end
          agent = request_agent_context
          actual_cost = @audit.dig(:'provider:response', :data, :estimated_cost_usd)
          cost_usd = actual_cost || estimate_cost(input_tokens, output_tokens)
          log.debug("[pipeline][metering] action=build provider=#{@resolved_provider} model=#{@resolved_model} input=#{input_tokens} output=#{output_tokens}")
          event = Steps::Metering.build_event(
            provider:           @resolved_provider,
            model_id:           @resolved_model,
            offering_id:        @resolved_offering_id,
            offering_metadata:  @resolved_offering_metadata,
            tier:               tier,
            request_type:       if @request.respond_to?(:request_type)
                                  @request.request_type
                                else
                                  (@request.respond_to?(:metadata) && @request.metadata.is_a?(Hash) ? (@request.metadata[:task] || @request.metadata[:request_type] || 'chat') : 'chat')
                                end,
            input_tokens:       input_tokens,
            output_tokens:      output_tokens,
            latency_ms:         latency_ms,
            wall_clock_ms:      wall_clock_ms,
            cost_usd:           cost_usd,
            request_id:         @request.id,
            conversation_id:    @request.conversation_id,
            correlation_id:     @tracing&.dig(:correlation_id),
            caller:             @request.caller,
            identity:           metering_identity,
            billing:            @request.billing,
            agent_id:           agent[:id],
            task_id:            agent[:task_id],
            routing_reason:     @audit.dig(:'routing:provider_selection', :data, :reason),
            messages:           @request.messages,
            response_content:   extract_response_content,
            response_thinking:  extract_thinking,
            context_accounting: finalize_context_accounting
          )
          Steps::Metering.publish_or_spool(event)
          flush_deferred_tool_audits
        rescue StandardError => e
          @warnings << "metering error: #{e.message}"
          handle_exception(e, level: :warn, operation: 'llm.pipeline.step_metering')

          # Attempt to spool the event so billing isn't lost even if publish fails.
          begin
            Legion::LLM::Metering.spool_event(event) if event
          rescue StandardError => spool_e
            handle_exception(spool_e, level: :error, operation: 'llm.pipeline.step_metering.spool_fallback')
          end
        end

        def estimate_cost(input_tokens, output_tokens)
          model_id = metering_model_id
          if (input_tokens + output_tokens).zero? && model_id
            log.warn(
              "[llm][metering] zero_tokens request_id=#{@request.id} " \
              "provider=#{@resolved_provider || 'none'} model=#{model_id} cost_estimate_skipped=true"
            )
            return nil
          end

          estimated = Legion::LLM::Metering::Pricing.estimate(
            model_id: model_id, input_tokens: input_tokens, output_tokens: output_tokens
          )
          if estimated.nil? && model_id
            log.warn(
              "[llm][metering] cost_estimate_unavailable request_id=#{@request.id} " \
              "provider=#{@resolved_provider || 'none'} model=#{model_id}"
            )
          end
          estimated
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.estimate_cost')
          nil
        end

        def metering_model_id
          metadata = @resolved_offering_metadata
          return @resolved_model unless metadata.is_a?(Hash)

          metadata[:canonical_model_alias] || metadata['canonical_model_alias'] || @resolved_model
        end

        def request_agent_context
          direct_agent = normalize_agent_context(@request.agent)
          return direct_agent unless direct_agent.empty?

          caller = @request.caller
          return {} unless caller.is_a?(Hash)

          normalize_agent_context(caller[:agent] || caller['agent'])
        end

        def normalize_agent_context(value)
          return {} unless value.is_a?(Hash)

          value.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
        end

        def metering_identity
          return Legion::LLM::PublisherIdentity.current unless @request.caller.is_a?(Hash) && @request.caller.any?

          @request.caller
        end

        def step_context_store
          conv_id = @request.conversation_id
          return unless conv_id

          log.debug("[pipeline][context_store] action=store conversation_id=#{conv_id} message_count=#{@request.messages.size}")

          @request.messages.each do |msg|
            next unless msg.is_a?(Hash)

            typed_msg = Types::Message.build(
              role:            msg[:role]&.to_sym || msg['role']&.to_sym || :user,
              content:         msg[:content] || msg['content'],
              task_id:         @request.respond_to?(:task_id) ? @request.task_id : nil,
              conversation_id: conv_id,
              tool_calls:      msg[:tool_calls] || msg['tool_calls'],
              tool_call_id:    msg[:tool_call_id] || msg['tool_call_id'],
              name:            msg[:name] || msg['name']
            )

            attrs = {
              role:            typed_msg.role,
              content:         typed_msg.text,
              conversation_id: conv_id,
              task_id:         typed_msg.task_id
            }

            attrs[:tool_calls]   = typed_msg.tool_calls   if typed_msg.tool_calls
            attrs[:tool_call_id] = typed_msg.tool_call_id if typed_msg.tool_call_id
            attrs[:name]         = typed_msg.name if typed_msg.name

            Conversation.append(conv_id, **attrs)
          end

          # Persist intermediate tool-use messages from the native tool loop
          persist_tool_loop_messages(conv_id) if @tool_loop_messages

          assistant_response = nil
          response_text = canonical_response_text(@raw_response)
          if response_text && !response_text.empty?
            tokens = @extracted_tokens || extract_tokens

            # Capture tool_calls from the tool loop's final assistant message
            final_tool_calls = tool_loop_final_tool_calls

            typed_assistant = Types::Message.build(
              role:            :assistant,
              content:         response_text,
              provider:        @resolved_provider,
              model:           @resolved_model,
              input_tokens:    tokens.respond_to?(:input_tokens) ? tokens.input_tokens : nil,
              output_tokens:   tokens.respond_to?(:output_tokens) ? tokens.output_tokens : nil,
              conversation_id: conv_id,
              task_id:         @request.respond_to?(:task_id) ? @request.task_id : nil
            )
            conv_attrs = {
              role:          typed_assistant.role,
              content:       typed_assistant.content,
              provider:      typed_assistant.provider,
              model:         typed_assistant.model,
              input_tokens:  typed_assistant.input_tokens,
              output_tokens: typed_assistant.output_tokens
            }
            conv_attrs[:tool_calls] = final_tool_calls if final_tool_calls && !final_tool_calls.empty?

            Conversation.append(conv_id, **conv_attrs)
            assistant_response = response_text
          end

          trigger_async_curation(conv_id, @request.messages, assistant_response)

          @timeline.record(
            category: :internal, key: 'context:stored',
            direction: :internal, detail: "stored to #{conv_id}",
            from: 'pipeline', to: 'conversation_store'
          )
        end

        # Persist the intermediate assistant/tool messages generated during the native tool loop.
        # The loop appends: { role: :assistant, tool_calls: [...] } then { role: :tool, tool_call_id: ..., content: ... }
        # Skip the first N messages (original inputs) and the last message (final assistant — stored by @raw_response).
        def persist_tool_loop_messages(conv_id)
          skip_count = @request.messages.size
          intermediate = @tool_loop_messages[skip_count...-1]
          return unless intermediate && !intermediate.empty?

          task_id = @request.respond_to?(:task_id) ? @request.task_id : nil
          intermediate.each do |msg|
            role    = msg[:role]&.to_sym || :assistant
            content = msg[:content]

            attrs = { role: role, content: content, conversation_id: conv_id, task_id: task_id }
            attrs[:tool_calls]   = msg[:tool_calls]   if msg[:tool_calls]
            attrs[:tool_call_id] = msg[:tool_call_id] if msg[:tool_call_id]
            attrs[:name]         = msg[:name]         if msg[:name]

            Conversation.append(conv_id, **attrs)
          end
          log.debug("[pipeline][context_store] action=store_tool_loop_messages conversation_id=#{conv_id} stored=#{intermediate.size}")
        end

        # Extract tool_calls from the tool loop's final assistant message (the last entry).
        def tool_loop_final_tool_calls
          return nil if @tool_loop_messages.nil? || @tool_loop_messages.empty?

          last = @tool_loop_messages.last
          return nil unless last.is_a?(Hash) && last[:role].to_s == 'assistant'

          tool_calls = last[:tool_calls]
          return nil unless tool_calls && !tool_calls.empty?

          # Convert to plain hashes for storage
          tool_calls.map { |tc| tc.is_a?(Hash) ? tc : tc.to_h }
        end

        def trigger_async_curation(conv_id, turn_messages, assistant_response)
          Context::Curator.new(conversation_id: conv_id)
                          .curate_turn(turn_messages:      turn_messages,
                                       assistant_response: assistant_response)
        rescue StandardError => e
          @warnings << "context_curation trigger failed: #{e.message}"
          handle_exception(e, level: :warn, operation: 'llm.pipeline.trigger_async_curation', conversation_id: conv_id)
        end

        def step_response_return
          populate_response_stats
          fire_pipeline_observation
          record_applied_to_gaia
        end

        def populate_response_stats
          @applied_signals[:response_stats] = {
            output_tokens:   @extracted_tokens.respond_to?(:output_tokens) ? @extracted_tokens.output_tokens.to_i : 0,
            provider:        @resolved_provider,
            model:           @resolved_model,
            tier:            @resolved_tier,
            latency_ms:      if @timestamps&.dig(:provider_start) && @timestamps[:provider_end]
                               ((@timestamps[:provider_end] - @timestamps[:provider_start]) * 1000).round
                             else
                               0
                             end,
            exchange_id:     @exchange_id,
            conversation_id: @request.conversation_id
          }
        end

        def fire_pipeline_observation
          return unless defined?(::Legion::Gaia) && ::Legion::Gaia.respond_to?(:observe_from_pipeline)

          identity = @request.caller&.dig(:requested_by, :identity)
          caller_type = @request.caller&.dig(:requested_by, :type)
          return unless identity && caller_type&.to_sym == :human

          exchange_id = @exchange_id || @request.id
          ::Legion::Gaia.observe_from_pipeline(
            identity:    identity,
            caller:      @request.caller,
            exchange_id: exchange_id
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.response_return.observe_pipeline')
        end

        def record_applied_to_gaia
          return unless defined?(::Legion::Gaia) && ::Legion::Gaia.respond_to?(:record_response_applied)
          return if @applied_signals[:advisory_id].nil? && @applied_signals[:behavioral_synapse_ids].empty?

          identity = @request.caller&.dig(:requested_by, :identity)
          ::Legion::Gaia.record_response_applied(
            advisory_id: @applied_signals[:advisory_id],
            identity:    identity,
            applied:     @applied_signals.dup
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.response_return.record_applied')
        end

        def finalize_context_accounting
          tokens = @context_accounting[:tokens]
          tokens[:request_message_estimated_tokens] = ContextAccounting.estimate_message_tokens(@request.messages)

          final_estimate =
            tokens[:request_message_estimated_tokens].to_i +
            effective_history_tokens(tokens) +
            tokens[:rag_injected_estimated_tokens].to_i +
            tokens[:system_prompt_estimated_tokens].to_i +
            tokens[:tool_definition_estimated_tokens].to_i

          tokens[:final_context_estimated_tokens] = final_estimate

          provider_input = provider_input_tokens_for_accounting
          provider_cached = provider_cached_input_tokens_for_accounting
          provider_cache_creation = provider_cache_creation_tokens_for_accounting
          provider_thinking = provider_thinking_tokens_for_accounting
          if provider_input.positive? || provider_cached.positive? || provider_cache_creation.positive? || provider_thinking.positive?
            @context_accounting[:status] = :provider_reconciled
            @context_accounting[:reconciliation] = {
              provider_input_tokens:          provider_input,
              provider_cached_input_tokens:   provider_cached,
              provider_cache_creation_tokens: provider_cache_creation,
              provider_thinking_tokens:       provider_thinking,
              estimated_input_tokens:         final_estimate,
              delta_tokens:                   provider_input - final_estimate
            }
            @context_accounting[:events] << ContextAccounting.event(
              event_type:    :provider_reconciliation,
              component:     :provider_input,
              before_tokens: final_estimate,
              after_tokens:  provider_input
            )
          end

          @context_accounting
        end

        def effective_history_tokens(tokens)
          loaded = tokens[:loaded_history_estimated_tokens].to_i
          saved = tokens[:curation_saved_estimated_tokens].to_i +
                  tokens[:archive_saved_estimated_tokens].to_i +
                  tokens[:stripped_thinking_estimated_tokens].to_i +
                  tokens[:context_window_saved_estimated_tokens].to_i
          [loaded - saved, 0].max
        end

        def provider_input_tokens_for_accounting
          @extracted_tokens ||= extract_tokens
          return @extracted_tokens.input_tokens.to_i if @extracted_tokens.respond_to?(:input_tokens)

          0
        end

        def provider_cached_input_tokens_for_accounting
          @extracted_tokens ||= extract_tokens
          return @extracted_tokens.cache_read_tokens.to_i if @extracted_tokens.respond_to?(:cache_read_tokens)
          return @extracted_tokens.cached_input_tokens.to_i if @extracted_tokens.respond_to?(:cached_input_tokens)

          0
        end

        def provider_cache_creation_tokens_for_accounting
          @extracted_tokens ||= extract_tokens
          return @extracted_tokens.cache_write_tokens.to_i if @extracted_tokens.respond_to?(:cache_write_tokens)
          return @extracted_tokens.cache_creation_tokens.to_i if @extracted_tokens.respond_to?(:cache_creation_tokens)

          0
        end

        def provider_thinking_tokens_for_accounting
          @extracted_tokens ||= extract_tokens
          return @extracted_tokens.thinking_tokens.to_i if @extracted_tokens.respond_to?(:thinking_tokens)

          details = @extracted_tokens.output_tokens_details if @extracted_tokens.respond_to?(:output_tokens_details)
          return details[:reasoning_tokens].to_i if details.is_a?(Hash) && details[:reasoning_tokens]

          0
        end

        def build_response
          @extracted_tokens ||= extract_tokens

          content = canonical_response_text(@raw_response) || @raw_response.to_s

          msg = Types::Message.build(
            role:            :assistant,
            content:         content,
            provider:        @resolved_provider,
            model:           @resolved_model,
            input_tokens:    @extracted_tokens.respond_to?(:input_tokens) ? @extracted_tokens.input_tokens : nil,
            output_tokens:   @extracted_tokens.respond_to?(:output_tokens) ? @extracted_tokens.output_tokens : nil,
            conversation_id: @request.conversation_id
          )

          @timestamps[:returned] = Time.now

          timeline_events = @_response_timeline_snapshot || @timeline.events
          timeline_parts = @_response_participants_snapshot || @timeline.participants
          warnings_snapshot = @_response_warnings_snapshot || @warnings

          log.debug("[pipeline][build_response] action=build request_id=#{@request.id} provider=#{@resolved_provider} model=#{@resolved_model}")

          # Synchronous delivery attribution hook (H2-llm)
          # Records what signals (GAIA hints, role mappings, etc) were actually applied to the final route.
          emit_final_delivery_attribution

          Response.build(
            request_id:      @request.id,
            conversation_id: @request.conversation_id || "conv_#{SecureRandom.hex(8)}",
            message:         msg.to_h,
            routing:         build_response_routing,
            tokens:          build_response_tokens,
            thinking:        extract_thinking,
            stop:            extract_stop_reason,
            tools:           response_tool_calls,
            stream:          @request.stream == true,
            cache:           build_response_cache,
            cost:            estimate_response_cost,
            timestamps:      @timestamps,
            enrichments:     @enrichments,
            audit:           @audit.merge(context_accounting: @context_accounting),
            timeline:        timeline_events,
            participants:    timeline_parts,
            warnings:        warnings_snapshot,
            tracing:         @tracing,
            caller:          @request.caller,
            classification:  @request.classification,
            billing:         @request.billing,
            test:            @request.test,
            quality:         @confidence_score&.to_h,
            features:        build_response_features
          )
        end

        def emit_final_delivery_attribution
          keys = @applied_signals.is_a?(Hash) ? @applied_signals[:envelope_keys] : []
          return if keys.nil? || keys.empty?

          log.info("[pipeline][attribution] action=emit_final_delivery signals=#{keys.join(',')}")
          @audit[:'delivery:attribution'] = {
            applied_signals: @applied_signals,
            timestamp:       Time.now
          }
        end

        def requested_deferred_tool_names
          return [] unless @request.respond_to?(:metadata)

          metadata = @request.metadata || {}
          requested = metadata[:requested_tools] || metadata['requested_tools'] || []
          Array(requested).map { |name| name.to_s.tr('.', '_') }.reject(&:empty?)
        end

        def build_response_routing
          routing = {
            provider: @resolved_provider,
            instance: @resolved_instance,
            model:    @resolved_model,
            tier:     @resolved_tier
          }.compact
          routing[:offering_id] = @resolved_offering_id if @resolved_offering_id
          routing[:offering_metadata] = @resolved_offering_metadata if @resolved_offering_metadata&.any?

          routing_audit = @audit[:'routing:provider_selection']
          if routing_audit.is_a?(Hash) && routing_audit[:data].is_a?(Hash)
            routing[:strategy] = routing_audit[:data][:strategy]
            routing[:tier]     = routing_audit[:data][:tier]
          end

          routing[:escalated] = @escalation_history.size > 1
          routing[:escalation_chain] = @escalation_history if @escalation_history.any?
          routing[:route_attempts] = @route_attempts.dup if @route_attempts.any?

          routing[:latency_ms] = ((@timestamps[:provider_end] - @timestamps[:provider_start]) * 1000).round if @timestamps[:provider_start] && @timestamps[:provider_end]

          routing
        end

        def build_response_tokens
          tokens = @extracted_tokens
          return tokens unless tokens.respond_to?(:input_tokens)

          input  = tokens.input_tokens.to_i
          output = tokens.output_tokens.to_i
          result = {
            input_tokens:       input,
            output_tokens:      output,
            # Backwards-compatible aliases used by token_value/inference_token_value helpers
            input:              input,
            output:             output,
            cache_read_tokens:  tokens.respond_to?(:cache_read_tokens) ? tokens.cache_read_tokens.to_i : 0,
            cache_write_tokens: tokens.respond_to?(:cache_write_tokens) ? tokens.cache_write_tokens.to_i : 0,
            total:              input + output
          }

          # Preserve output token breakdown (e.g. reasoning_tokens from Responses API)
          if tokens.respond_to?(:output_tokens_details) && tokens.output_tokens_details.is_a?(Hash) && !tokens.output_tokens_details.empty?
            result[:output_tokens_details] = tokens.output_tokens_details
          end

          context_window = @resolved_offering_metadata&.dig(:limits, :context_window) ||
                           @resolved_offering_metadata&.dig(:context_window)
          if context_window&.to_i&.positive?
            result[:context_window] = context_window.to_i
            result[:utilization]    = (result[:input_tokens].to_f / context_window.to_i).round(4)
            result[:headroom]       = context_window.to_i - result[:input_tokens]
          end

          result
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.build_response_tokens')
          @extracted_tokens
        end

        def extract_response_content
          return nil unless @raw_response

          if @raw_response.respond_to?(:text)
            @raw_response.text
          elsif @raw_response.respond_to?(:content)
            @raw_response.content
          elsif @raw_response.is_a?(Hash) && @raw_response[:content]
            @raw_response[:content]
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.extract_response_content')
          nil
        end

        def extract_thinking
          return nil unless @raw_response

          thinking = if @raw_response.respond_to?(:thinking) && @raw_response.thinking
                       @raw_response.thinking
                     elsif @raw_response.respond_to?(:metadata) && @raw_response.metadata.is_a?(Hash)
                       @raw_response.metadata[:thinking] || @raw_response.metadata['thinking']
                     end
          return nil unless thinking

          payload = normalize_thinking_payload(thinking)
          return nil unless payload

          payload[:config] = @request.thinking if @request.thinking
          payload
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.extract_thinking')
          nil
        end

        # Extract text content from a canonical response or hash-shaped legacy result.
        def canonical_response_text(response)
          return response.text if response.respond_to?(:text) && !response.respond_to?(:[])

          if response.respond_to?(:content)
            response.content
          else
            (response.respond_to?(:[]) ? response[:content] || response[:result] || response[:text] : nil)
          end
        end

        def normalize_thinking_payload(thinking)
          if thinking.is_a?(Hash)
            normalized = thinking.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
            content = normalized[:content] || normalized[:text]
            signature = normalized[:signature]
          elsif thinking.respond_to?(:content) && thinking.respond_to?(:signature)
            content = thinking.content
            signature = thinking.signature
          elsif thinking.respond_to?(:text)
            content = thinking.text
            signature = thinking.respond_to?(:signature) ? thinking.signature : nil
          else
            content = thinking.is_a?(String) ? thinking : nil
            signature = nil
          end
          content = content.to_s.strip unless content.nil?
          return nil if content.to_s.empty? && signature.to_s.empty?

          { content: content, signature: signature, enabled: true }.compact
        end

        def build_response_cache
          return {} unless @extracted_tokens

          cache_read  = @extracted_tokens.respond_to?(:cache_read_tokens) ? @extracted_tokens.cache_read_tokens.to_i : 0
          cache_write = @extracted_tokens.respond_to?(:cache_write_tokens) ? @extracted_tokens.cache_write_tokens.to_i : 0
          return {} if cache_read.zero? && cache_write.zero?

          {
            read_tokens:  cache_read,
            write_tokens: cache_write,
            hit:          cache_read.positive?,
            strategy:     @request.respond_to?(:cache) ? @request.cache : nil
          }
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.build_response_cache')
          {}
        end

        def build_response_features
          features = {}
          features[:thinking]       = true if @request.thinking
          features[:streaming]      = true if @request.stream == true
          features[:tools]          = true if response_tool_calls&.any?
          features[:prompt_caching] = true if @extracted_tokens.respond_to?(:cache_read_tokens) &&
                                              (@extracted_tokens.cache_read_tokens.to_i.positive? ||
                                               @extracted_tokens.cache_write_tokens.to_i.positive?)
          features[:enrichments]    = true if @enrichments&.any?
          features.empty? ? nil : features
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.build_response_features')
          nil
        end

        def extract_stop_reason
          reason = if @raw_response.respond_to?(:stop_reason)
                     @raw_response.stop_reason&.to_sym
                   elsif @raw_response.respond_to?(:tool_calls) && @raw_response.tool_calls&.any?
                     stop_reason_for_tool_calls(response_tool_calls)
                   end
          { reason: reason || :end_turn }
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.extract_stop_reason')
          { reason: :end_turn }
        end

        def stop_reason_for_tool_calls(tool_calls)
          return nil if tool_calls.empty?

          tool_calls.each do |tc|
            source = tc.source
            next unless source.is_a?(Hash)

            type = source[:type] || source['type']
            next unless %i[special registry extension].include?(type&.to_sym)

            # LegionIO tool: only return :pause_turn if it hasn't been executed yet.
            # If the tool already has a result, the server-side tool loop completed
            # and we should fall through to :end_turn.
            tc_result = tc.respond_to?(:result) ? tc.result : (tc[:result] || tc['result'])
            return :pause_turn if tc_result.nil?
          end

          # All LegionIO tools have results (already executed), or only
          # client-side tools remain — treat as normal tool_use for the client.
          :tool_use
        end

        def estimate_response_cost
          @extracted_tokens ||= extract_tokens
          input  = @extracted_tokens.respond_to?(:input_tokens) ? @extracted_tokens.input_tokens : @extracted_tokens[:input].to_i
          output = @extracted_tokens.respond_to?(:output_tokens) ? @extracted_tokens.output_tokens : @extracted_tokens[:output].to_i
          return {} unless @resolved_model && (input + output).positive?

          estimated = Metering::Pricing.estimate(
            model_id:      @resolved_model,
            input_tokens:  input,
            output_tokens: output
          )
          { estimated_usd: estimated, provider: @resolved_provider, model: @resolved_model }
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.estimate_response_cost')
          {}
        end

        def response_tool_calls
          raw_tool_calls = @raw_response.respond_to?(:tool_calls) ? @raw_response.tool_calls : nil
          return build_response_tool_calls(raw_tool_calls) if raw_tool_calls&.any?

          # Fall back to typed ToolCall objects from pending history when the final
          # model response completed after server-side tool execution.
          typed_from_history = @pending_tool_history
                               .filter_map { |entry| entry[:typed_call] }
          return typed_from_history if typed_from_history.any?

          []
        end

        def build_response_tool_calls(tool_calls)
          tool_timeline = build_tool_timeline_index

          # Track per-tool-name call order so each tool call maps to its timeline entry
          call_index = Hash.new(0)

          Array(tool_calls).map do |tool_call|
            tc_id   = tool_call_field(tool_call, :id)
            tc_name = tool_call_field(tool_call, :name)
            tc_args = tool_call_field(tool_call, :arguments) || {}

            call_index[tc_name] += 1
            entry_key = call_index[tc_name] > 1 ? "#{tc_name}:#{call_index[tc_name]}" : tc_name
            timeline_data = tool_timeline[entry_key] || tool_timeline[tc_name] || {}
            pending_data = pending_tool_call_data(tc_id, tc_name)

            Legion::LLM::Types::ToolCall.build(
              id:          tc_id,
              name:        tc_name,
              arguments:   tc_args,
              exchange_id: tool_call_field(tool_call, :exchange_id) || pending_data[:exchange_id] || timeline_data[:exchange_id],
              source:      tool_call_field(tool_call, :source) || pending_data[:source] || timeline_data[:source],
              status:      tool_call_field(tool_call, :status) || pending_data[:status] || timeline_data[:status],
              duration_ms: tool_call_field(tool_call, :duration_ms) || pending_data[:duration_ms] || timeline_data[:duration_ms],
              result:      tool_call_field(tool_call, :result) || pending_data[:result] || timeline_data[:result],
              error:       tool_call_field(tool_call, :error) || pending_data[:error]
            )
          end
        end

        def pending_tool_call_data(tool_call_id, tool_name)
          entry = @pending_tool_history&.find do |candidate|
            candidate[:tool_call_id] == tool_call_id || candidate[:tool_name] == tool_name
          end
          return {} unless entry

          typed_call = entry[:typed_call]
          {
            exchange_id: typed_call&.exchange_id,
            source:      typed_call&.source,
            status:      typed_call&.status,
            duration_ms: typed_call&.duration_ms,
            result:      typed_call&.result || entry[:result],
            error:       typed_call&.error || (entry[:result] if entry[:error])
          }.compact
        end

        def build_tool_timeline_index
          index = {}
          call_counts = Hash.new(0)
          @timeline.events.each do |event|
            key = event[:key]
            data = event[:data] || {}

            if key&.start_with?('tool:execute:')
              tool_name = key.sub('tool:execute:', '')
              call_counts[tool_name] += 1
              entry_key = call_counts[tool_name] > 1 ? "#{tool_name}:#{call_counts[tool_name]}" : tool_name
              index[entry_key] = {
                tool_name:   tool_name,
                exchange_id: event[:exchange_id],
                source:      data[:source],
                status:      data[:status],
                duration_ms: event[:duration_ms]
              }
            elsif key&.start_with?('tool:result:')
              tool_name = key.sub('tool:result:', '')
              # Match result to the most recent execute entry for this tool
              entry_key = (call_counts[tool_name] > 1 ? "#{tool_name}:#{call_counts[tool_name]}" : tool_name)
              index[entry_key][:result] = data[:result] if index[entry_key]
            end
          end

          index
        end
      end
    end
  end
end
