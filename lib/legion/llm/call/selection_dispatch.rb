# frozen_string_literal: true

require 'legion/llm/errors'
require 'legion/llm/inference/request'

module Legion
  module LLM
    module Call
      # Exact local dispatch (SSOT v3 §15.1). Acquires the exact callable handle
      # named by a Selection (never re-resolves by provider/model), invokes the
      # operation-specific callable method, normalizes a provider StandardError
      # into a Phase 1 ProviderOutcome via that exact callable's
      # normalize_dispatch_error, and always releases the owned DispatchLease in
      # ensure. It never rescues a typed routing/provider outcome into a
      # success-shaped Hash.
      module SelectionDispatch
        extend Legion::Logging::Helper

        # Immutable dispatch result. `value` holds the provider return separately
        # from the normalized `outcome`; the outcome never embeds the body.
        class Result
          attr_reader :value, :outcome

          def self.success(value:)
            new(value:   value,
                outcome: Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                  kind: :success, reason: 'provider call completed'
                ))
          end

          def self.failure(outcome:)
            raise ArgumentError, 'SelectionDispatch::Result.failure requires a non-success ProviderOutcome' if outcome.kind == :success

            new(value: nil, outcome: outcome)
          end

          def initialize(value:, outcome:)
            @value = value
            @outcome = outcome
            freeze
          end

          def success? = @outcome.kind == :success
          def failure? = !success?
        end

        # Protected operation args removed before passthrough, per operation.
        # Argument validation and protected-key extraction (programming errors)
        # happen BEFORE handle acquisition and the provider-error rescue, so an
        # ArgumentError never becomes a normalized provider failure.
        def self.call(attempt_context:, arguments:, dispatch_lease: nil, &block)
          raise ArgumentError, 'arguments must be a Hash' unless arguments.is_a?(Hash)

          selection = attempt_context.selection
          invocation = plan_invocation(operation: selection.operation, model: selection.model,
                                       arguments: arguments, block: block)

          owned_lease = dispatch_lease.nil?
          lease = dispatch_lease || Legion::Extensions::Llm::Inventory::Registry.acquire(
            callable_handle: selection.callable_handle
          )
          log.debug("[llm][selection_dispatch] action=lease_acquired handle=#{selection.callable_handle.handle_id} " \
                    "lease=#{lease.lease_id}")
          callable = lease.callable

          begin
            Result.success(value: invocation.call(callable))
          rescue StandardError => e
            log.warn("[llm][selection_dispatch] action=dispatch_failed class=#{e.class.name} " \
                     "message=#{e.message.to_s[0, 200]}")
            raise if daemon_fault?(e)

            Result.failure(outcome: normalize(callable: callable, error: e))
          ensure
            lease.release if owned_lease && !lease.released?
          end
        end

        def self.daemon_fault?(error)
          error.is_a?(::NoMethodError) || error.is_a?(::ArgumentError) ||
            error.is_a?(::NotImplementedError) || error.is_a?(::TypeError)
        end
        private_class_method :daemon_fault?

        # Normalize a provider error through the exact callable's Phase 1
        # normalizer. A normalizer that raises or returns the wrong type is a
        # programming failure — report and re-raise, never a silent success.
        def self.normalize(callable:, error:)
          outcome = callable.normalize_dispatch_error(error: error)
          unless outcome.is_a?(Legion::Extensions::Llm::Routing::ProviderOutcome)
            raise TypeError,
                  "normalize_dispatch_error returned #{outcome.class}, expected ProviderOutcome"
          end
          log.warn("[llm][selection_dispatch] action=dispatch_normalized kind=#{outcome.kind} " \
                   "reason=#{outcome.reason.to_s[0, 200]}")
          outcome
        rescue StandardError => e
          # Log the ORIGINAL dispatch error too — a normalizer that raises must never
          # mask the provider error it was asked to classify; that mask is what made this
          # class of bug undiagnosable from the daemon log (the original was lost entirely).
          handle_exception(e, level: :warn, operation: 'llm.call.selection_dispatch.normalize_error',
                              handled: false, lane_id: nil,
                              original_error_class: error.class.name,
                              original_error_message: error.message.to_s.dup.force_encoding(::Encoding::UTF_8).scrub('?')[0, 512])
          log.warn("[llm][selection_dispatch] action=normalizer_failed class=#{e.class.name} " \
                   "message=#{e.message.to_s[0, 200]}")
          raise
        end
        private_class_method :normalize

        # Validate arguments and build a proc that invokes the exact
        # operation→callable-method mapping (§15.1). Validation raises
        # ArgumentError here (before acquisition/rescue). The Selection model is
        # authoritative; an arguments[:model] is rejected rather than overriding.
        def self.plan_invocation(operation:, model:, arguments:, block:)
          args = arguments.dup
          reject_model!(args)

          case operation
          when :chat
            messages = canonical_messages!(args)
            ->(c) { c.chat(messages, model: model, **args) }
          when :stream_chat
            messages = canonical_messages!(args)
            ->(c) { c.stream_chat(messages, model: model, **args, &block) }
          when :embed
            text = require_key!(args, :text)
            ->(c) { c.embed(text: text, model: model, **args) }
          when :image
            prompt = require_key!(args, :prompt)
            size = require_key!(args, :size)
            ->(c) { c.image(prompt: prompt, model: model, size: size, **args) }
          when :transcribe
            audio_file = require_positional!(args, :audio_file)
            language = require_key!(args, :language)
            ->(c) { c.transcribe(audio_file, model: model, language: language, **args) }
          when :translate
            audio_file = require_positional!(args, :audio_file)
            language = require_key!(args, :language)
            ->(c) { c.translate(audio_file, model: model, language: language, **args) }
          when :speak
            text = require_positional!(args, :text)
            voice = args.key?(:voice) ? args.delete(:voice) : nil
            ->(c) { c.speak(text, model: model, voice: voice, **args) }
          when :moderate
            input = require_positional!(args, :input)
            ->(c) { c.moderate(input: input, model: model, **args) }
          when :count_tokens
            messages = canonical_messages!(args)
            ->(c) { c.count_tokens(messages: messages, model: model, **args) }
          else
            raise ArgumentError, "unsupported operation for dispatch: #{operation.inspect}"
          end
        end
        private_class_method :plan_invocation

        # Dispatch-boundary rehydration (0.8.0): the callable receives
        # Array<Canonical::Message> for every exact message operation. Wire
        # hashes and plain strings are translated through the single
        # canonicalization shared with Inference::Request; anything else
        # raises before the lease is acquired.
        def self.canonical_messages!(args)
          messages = require_key!(args, :messages)
          Legion::LLM::Inference::Request.canonicalize_messages(messages)
        end
        private_class_method :canonical_messages!

        def self.reject_model!(args)
          return unless args.key?(:model)

          raise ArgumentError, 'arguments[:model] is not permitted; the Selection model is authoritative'
        end
        private_class_method :reject_model!

        # keyword-style protected arg: present (empty Array allowed for messages), removed once.
        def self.require_key!(args, key)
          raise ArgumentError, "operation argument #{key.inspect} is required" unless args.key?(key)

          args.delete(key)
        end
        private_class_method :require_key!

        # positional protected arg: value may not be nil.
        def self.require_positional!(args, key)
          value = require_key!(args, key)
          raise ArgumentError, "operation argument #{key.inspect} is required" if value.nil?

          value
        end
        private_class_method :require_positional!
      end
    end
  end
end
