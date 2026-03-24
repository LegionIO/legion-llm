# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      class Executor
        attr_reader :request, :profile, :timeline, :tracing, :enrichments,
                    :audit, :warnings

        STEPS = %i[
          tracing_init idempotency conversation_uuid context_load
          rbac classification billing gaia_advisory rag_context mcp_discovery
          routing request_normalization provider_call response_normalization
          tool_calls context_store post_response response_return
        ].freeze

        PRE_PROVIDER_STEPS = %i[
          tracing_init idempotency conversation_uuid context_load
          rbac classification billing gaia_advisory rag_context mcp_discovery
          routing request_normalization
        ].freeze

        POST_PROVIDER_STEPS = %i[
          response_normalization tool_calls context_store post_response response_return
        ].freeze

        def initialize(request)
          @request      = request
          @profile      = Profile.derive(request.caller)
          @timeline     = Timeline.new
          @tracing      = nil
          @enrichments  = {}
          @audit        = {}
          @warnings     = []
          @timestamps   = { received: Time.now }
          @raw_response = nil
          @exchange_id  = nil
          @resolved_provider = nil
          @resolved_model    = nil
        end

        def call
          execute_steps
          build_response
        end

        def call_stream(&block)
          return call unless block

          execute_pre_provider_steps
          step_provider_call_stream(&block)
          execute_post_provider_steps
          build_response
        end

        private

        def execute_steps
          STEPS.each do |step|
            next if Profile.skip?(@profile, step)

            send(:"step_#{step}")
          end
        end

        def step_tracing_init
          @tracing = Tracing.init(existing: @request.tracing)
          @timeline.record(
            category: :internal, key: 'tracing:init',
            direction: :internal, detail: 'trace initialized',
            from: 'pipeline', to: 'pipeline'
          )
        end

        def step_idempotency; end

        def step_conversation_uuid; end

        def step_context_load
          conv_id = @request.conversation_id
          return unless conv_id

          history = ConversationStore.messages(conv_id)
          return if history.empty?

          @enrichments[:conversation_history] = history
          @timeline.record(
            category: :internal, key: 'context:loaded',
            direction: :internal, detail: "loaded #{history.size} prior messages",
            from: 'conversation_store', to: 'pipeline'
          )
        end

        def step_rbac
          @audit[:'rbac:permission_check'] = {
            outcome: :success, detail: 'permitted (not yet enforced)',
            duration_ms: 0, timestamp: Time.now
          }
          @timeline.record(
            category: :audit, key: 'rbac:permission_check',
            direction: :internal, detail: 'permitted (not yet enforced)',
            from: 'pipeline', to: 'rbac'
          )
        end

        def step_classification
          @audit[:'classification:scan'] = {
            outcome: :success, detail: 'scan not yet implemented',
            duration_ms: 0, timestamp: Time.now
          }
          @timeline.record(
            category: :audit, key: 'classification:scan',
            direction: :internal, detail: 'scan not yet implemented',
            from: 'pipeline', to: 'classification'
          )
        end

        def step_billing
          @audit[:'billing:budget_check'] = {
            outcome: :success, detail: 'budget check not yet implemented',
            duration_ms: 0, timestamp: Time.now
          }
          @timeline.record(
            category: :audit, key: 'billing:budget_check',
            direction: :internal, detail: 'budget check not yet implemented',
            from: 'pipeline', to: 'billing'
          )
        end

        def step_gaia_advisory; end

        def step_rag_context; end

        def step_mcp_discovery; end

        def step_routing
          @timestamps[:routing_start] = Time.now
          provider = @request.routing[:provider]
          model    = @request.routing[:model]
          intent   = @request.extra[:intent]
          tier     = @request.extra[:tier]

          if (intent || tier) && defined?(Router) && Router.routing_enabled?
            resolution = Router.resolve(intent: intent, tier: tier, model: model, provider: provider)
            if resolution
              provider = resolution.provider
              model    = resolution.model
              @audit[:'routing:provider_selection'] = {
                outcome: :success,
                detail: "selected #{provider}:#{model} via #{resolution.rule}",
                data: { strategy: resolution.rule, tier: resolution.tier },
                duration_ms: 0, timestamp: Time.now
              }
            end
          end

          @resolved_provider = provider || Legion::LLM.settings[:default_provider]
          @resolved_model    = model || Legion::LLM.settings[:default_model]

          @timeline.record(
            category: :audit, key: 'routing:provider_selection',
            direction: :internal, detail: "routed to #{@resolved_provider}:#{@resolved_model}",
            from: 'router', to: 'pipeline'
          )
        end

        def step_request_normalization
          @exchange_id = Tracing.exchange_id
        end

        def step_provider_call
          @timestamps[:provider_start] = Time.now
          @timeline.record(
            category: :provider, key: 'provider:request_sent',
            exchange_id: @exchange_id, direction: :outbound,
            detail: "calling #{@resolved_provider}",
            from: 'pipeline', to: "provider:#{@resolved_provider}"
          )

          opts = {
            model:    @resolved_model,
            provider: @resolved_provider
          }.compact

          session = RubyLLM.chat(**opts)

          (@request.tools || []).each do |tool|
            session.with_tool(tool) if tool.is_a?(Class)
          end

          ToolRegistry.tools.each { |t| session.with_tool(t) } if defined?(ToolRegistry)

          message_content = @request.messages.last&.dig(:content)
          @raw_response = message_content ? session.ask(message_content) : session

          @timestamps[:provider_end] = Time.now
          record_provider_response
        rescue Faraday::UnauthorizedError, Faraday::ForbiddenError => e
          raise Legion::LLM::AuthError, e.message
        rescue Faraday::TooManyRequestsError => e
          raise Legion::LLM::RateLimitError.new(e.message, retry_after: extract_retry_after(e))
        rescue Faraday::ServerError => e
          raise Legion::LLM::ProviderError, e.message
        rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
          raise Legion::LLM::ProviderDown, e.message
        end

        def record_provider_response
          @timeline.record(
            category: :provider, key: 'provider:response_received',
            exchange_id: @exchange_id, direction: :inbound,
            detail: 'response received',
            from: "provider:#{@resolved_provider}", to: 'pipeline',
            duration_ms: ((@timestamps[:provider_end] - @timestamps[:provider_start]) * 1000).to_i
          )
        end

        def extract_retry_after(error)
          return nil unless error.respond_to?(:response) && error.response.is_a?(Hash)

          error.response[:headers]&.fetch('retry-after', nil)&.to_i
        end

        def execute_pre_provider_steps
          PRE_PROVIDER_STEPS.each do |step|
            next if Profile.skip?(@profile, step)

            send(:"step_#{step}")
          end
        end

        def execute_post_provider_steps
          POST_PROVIDER_STEPS.each do |step|
            next if Profile.skip?(@profile, step)

            send(:"step_#{step}")
          end
        end

        def step_provider_call_stream(&)
          @timestamps[:provider_start] = Time.now
          @timeline.record(
            category: :provider, key: 'provider:request_sent',
            exchange_id: @exchange_id, direction: :outbound,
            detail: "streaming from #{@resolved_provider}",
            from: 'pipeline', to: "provider:#{@resolved_provider}"
          )

          opts = { model: @resolved_model, provider: @resolved_provider }.compact
          session = RubyLLM.chat(**opts)

          (@request.tools || []).each { |tool| session.with_tool(tool) if tool.is_a?(Class) }
          ToolRegistry.tools.each { |t| session.with_tool(t) } if defined?(ToolRegistry)

          message_content = @request.messages.last&.dig(:content)
          @raw_response = session.ask(message_content, &)

          @timestamps[:provider_end] = Time.now
          record_provider_response
        rescue Faraday::UnauthorizedError, Faraday::ForbiddenError => e
          raise Legion::LLM::AuthError, e.message
        rescue Faraday::TooManyRequestsError => e
          raise Legion::LLM::RateLimitError.new(e.message, retry_after: extract_retry_after(e))
        rescue Faraday::ServerError => e
          raise Legion::LLM::ProviderError, e.message
        rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
          raise Legion::LLM::ProviderDown, e.message
        end

        def step_response_normalization; end

        def step_tool_calls; end

        def step_context_store
          conv_id = @request.conversation_id
          return unless conv_id

          @request.messages.each do |msg|
            ConversationStore.append(conv_id,
                                     role:    msg[:role]&.to_sym || :user,
                                     content: msg[:content])
          end

          if @raw_response.respond_to?(:content) && @raw_response.content
            ConversationStore.append(conv_id,
                                     role:          :assistant,
                                     content:       @raw_response.content,
                                     provider:      @resolved_provider,
                                     model:         @resolved_model,
                                     input_tokens:  @raw_response.respond_to?(:input_tokens) ? @raw_response.input_tokens : nil,
                                     output_tokens: @raw_response.respond_to?(:output_tokens) ? @raw_response.output_tokens : nil)
          end

          @timeline.record(
            category: :internal, key: 'context:stored',
            direction: :internal, detail: "stored to #{conv_id}",
            from: 'pipeline', to: 'conversation_store'
          )
        end

        def step_post_response; end

        def step_response_return; end

        def build_response
          msg = if @raw_response.respond_to?(:content)
                  { role: :assistant, content: @raw_response.content }
                elsif @raw_response.is_a?(Hash) && @raw_response[:content]
                  @raw_response
                else
                  { role: :assistant, content: @raw_response.to_s }
                end

          @timestamps[:returned] = Time.now

          Response.build(
            request_id:      @request.id,
            conversation_id: @request.conversation_id || "conv_#{SecureRandom.hex(8)}",
            message:         msg,
            routing:         { provider: @resolved_provider, model: @resolved_model },
            tokens:          extract_tokens,
            stop:            { reason: :end_turn },
            timestamps:      @timestamps,
            enrichments:     @enrichments,
            audit:           @audit,
            timeline:        @timeline.events,
            participants:    @timeline.participants,
            warnings:        @warnings,
            tracing:         @tracing,
            caller:          @request.caller,
            classification:  @request.classification,
            billing:         @request.billing,
            test:            @request.test
          )
        end

        def extract_tokens
          return {} unless @raw_response.respond_to?(:input_tokens)

          input  = @raw_response.input_tokens.to_i
          output = @raw_response.output_tokens.to_i
          { input: input, output: output, total: input + output }
        end
      end
    end
  end
end
