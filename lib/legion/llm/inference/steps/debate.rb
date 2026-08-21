# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module Debate
          include Legion::Logging::Helper
          include Steps::Logging

          CHALLENGER_PROMPT = <<~PROMPT
            You are a critical analyst reviewing the following response. Your job is to identify
            weaknesses, logical flaws, unsupported assumptions, missing context, or alternative
            perspectives that were not considered. Be specific and constructive.

            Original question/request:
            %<question>s

            Advocate's response:
            %<advocate>s

            Provide a thorough critique. What is wrong, incomplete, or could be improved?
          PROMPT

          REBUTTAL_PROMPT = <<~PROMPT
            You originally provided a response to a question. A challenger has critiqued your
            response. Address the critique directly, defending valid points and conceding where
            the challenger identified genuine weaknesses.

            Original question/request:
            %<question>s

            Your original response:
            %<advocate>s

            Challenger's critique:
            %<challenger>s

            Provide a rebuttal that strengthens your position or acknowledges valid criticisms.
          PROMPT

          JUDGE_PROMPT = <<~PROMPT
            You are an impartial judge evaluating a multi-round debate about the following question.
            Your task is to evaluate the strength of each position, state which argument was stronger
            and why, assign confidence to the final position, then produce the most accurate,
            balanced, and complete answer possible.

            Original question/request:
            %<question>s

            Advocate's position:
            %<advocate>s

            Challenger's critique:
            %<challenger>s

            Advocate's rebuttal:
            %<rebuttal>s

            Respond using exactly these section labels:
            Evaluation: compare the advocate and challenger, state which side was stronger, and give confidence.
            Final answer: synthesize the final answer. Incorporate valid points from the critique while preserving
            what the advocate got right. Be direct and definitive.
          PROMPT

          def step_debate
            unless debate_enabled?(@request)
              log_step_debug(:debate, :skipped, reason: :disabled)
              return
            end
            unless @raw_response
              log_step_debug(:debate, :skipped, reason: :no_response)
              return
            end

            log_step_info(:debate, :start, message_count: @request.messages.size)
            debate_result = run_debate(@raw_response, @request)
            unless debate_result
              log_step_debug(:debate, :skipped, reason: :no_result)
              return
            end

            original_chars = extract_content(@raw_response).length
            @raw_response = debate_result[:synthetic_response]
            log.warn(
              "[llm][steps][debate] action=response_replaced request_id=#{@request&.id || 'none'} " \
              "original_chars=#{original_chars} synthetic_chars=#{debate_result[:synthetic_response].text.to_s.length} " \
              "rounds=#{debate_result[:rounds]}"
            )
            @applied_signals[:envelope_keys] << 'debate:applied' if @applied_signals.is_a?(Hash)
            @enrichments['debate:result'] = {
              content:   "debate completed: #{debate_result[:rounds]} rounds, judge synthesis produced",
              data:      debate_result[:metadata],
              timestamp: Time.now
            }

            @timeline.record(
              category: :internal, key: 'debate:completed',
              direction: :internal,
              detail: "rounds=#{debate_result[:rounds]} advocate=#{debate_result[:metadata][:advocate_model]} " \
                      "challenger=#{debate_result[:metadata][:challenger_model]} judge=#{debate_result[:metadata][:judge_model]}",
              from: 'pipeline', to: 'pipeline'
            )
            log_step_info(
              :debate,
              :complete,
              rounds:           debate_result[:rounds],
              advocate_model:   debate_result[:metadata][:advocate_model],
              challenger_model: debate_result[:metadata][:challenger_model],
              judge_model:      debate_result[:metadata][:judge_model]
            )
          rescue StandardError => e
            @warnings << "debate step error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.debate')
          end

          def debate_enabled?(request)
            explicit = request.extra[:debate] if request.extra.is_a?(Hash)
            return explicit unless explicit.nil?

            gaia_trigger = gaia_debate_trigger?(@enrichments)
            return true if gaia_trigger

            Legion::Settings[:llm][:debate][:enabled] == true
          end

          def gaia_debate_trigger?(enrichments)
            return false unless debate_setting(:gaia_auto_trigger) == true

            gaia = enrichments&.fetch('gaia:advisory', nil)
            advisory = gaia.is_a?(Hash) ? gaia[:data] : nil
            return false unless advisory.is_a?(Hash)

            advisory[:high_stakes] == true || advisory[:debate_recommended] == true
          end

          def run_debate(advocate_response, request)
            rounds      = resolve_debate_rounds(request)
            question    = extract_question(request)
            advocate_text = extract_content(advocate_response)

            models = select_debate_models(request)
            @warnings << models[:warning] if models[:warning]
            if models[:skip]
              log.warn(
                "[llm][steps][debate] action=skipped_insufficient_models request_id=#{request&.id || 'none'} " \
                "reason=#{models[:skip]} available_models=#{available_models.size}"
              )
              return nil
            end

            advocate_model    = models[:advocate]
            challenger_model  = models[:challenger]
            judge_model       = models[:judge]

            current_advocate = advocate_text
            log_debate_models(rounds, advocate_model, challenger_model, judge_model)
            current_challenger, current_rebuttal = run_debate_rounds(
              rounds: rounds, question: question, advocate_model: advocate_model,
              challenger_model: challenger_model, current_advocate: current_advocate
            )

            judge_synthesis = judge_debate(
              question:           question,
              advocate_text:      advocate_text,
              current_challenger: current_challenger,
              current_rebuttal:   current_rebuttal,
              judge_model:        judge_model
            )
            judge_sections = parse_judge_output(judge_synthesis)
            # G3: the synthetic response is a Canonical::Response — @raw_response
            # stays canonical through the pipeline (a Struct with a bare .content
            # member was the split-world seam; downstream readers are canonical
            # member reads).
            synthetic_response = Legion::Extensions::Llm::Canonical::Response.build(
              text: judge_sections[:final_answer].to_s
            )

            {
              synthetic_response: synthetic_response,
              rounds:             rounds,
              metadata:           debate_metadata(
                rounds: rounds, advocate_model: advocate_model, challenger_model: challenger_model,
                judge_model: judge_model, advocate_text: advocate_text,
                current_challenger: current_challenger, judge_sections: judge_sections,
                judge_synthesis: judge_synthesis
              )
            }
          end

          private

          def debate_setting(key)
            Legion::Settings[:llm][:debate][key]
          end

          def resolve_debate_rounds(request)
            requested = request.extra.is_a?(Hash) ? request.extra[:debate_rounds] : nil
            default   = debate_setting(:default_rounds)
            max       = debate_setting(:max_rounds)

            rounds = requested ? requested.to_i : default.to_i
            rounds = 1 if rounds < 1
            [rounds, max.to_i].min
          end

          def extract_question(request)
            # G3: canonical messages — the question is the last user
            # message's canonical .text.
            last_user = request.messages.select { |m| m.role.to_s == 'user' }.last
            last_user ? last_user.text.to_s : ''
          end

          # G3: the debate reads canonical responses. The advocate is the
          # pipeline's Canonical::Response (.text); the challenger/judge role
          # calls return the Inference::Response envelope (message Hash).
          # No Hash/.content duck-typing — a shape that is neither is a
          # contract fault, surfaced loud, never a Ruby inspect string.
          def extract_content(response)
            return response.text.to_s if response.is_a?(Legion::Extensions::Llm::Canonical::Response)

            if response.is_a?(Legion::LLM::Inference::Response)
              msg = response.message
              return (msg.is_a?(Hash) ? (msg[:content] || msg['content']) : msg.to_s).to_s
            end

            raise ArgumentError, "extract_content expects Canonical::Response or Inference::Response, got #{response.class}"
          end

          def select_debate_models(request)
            explicit_advocate   = debate_setting(:advocate_model)
            explicit_challenger = debate_setting(:challenger_model)
            explicit_judge      = debate_setting(:judge_model)

            # SSOT v3: the advocate is the exact lane that produced the primary
            # response (resolved provider/model), or an explicitly configured debate
            # advocate — never a configured default_model/default_provider.
            request_model    = @resolved_model || (request.routing.is_a?(Hash) ? request.routing[:model] : nil)
            request_provider = @resolved_provider || (request.routing.is_a?(Hash) ? request.routing[:provider] : nil)

            advocate_model = explicit_advocate ||
                             (request_provider && request_model ? "#{request_provider}:#{request_model}" : nil)

            if explicit_challenger && explicit_judge
              return {
                advocate:   advocate_model,
                challenger: explicit_challenger,
                judge:      explicit_judge
              }
            end

            available = available_models
            if available.size < 2
              warning = 'debate: fewer than 2 distinct models available; skipping debate'
              return {
                advocate:   advocate_model,
                challenger: explicit_challenger,
                judge:      explicit_judge,
                warning:    warning,
                skip:       :insufficient_distinct_models
              }
            end

            # Rotate through available models to ensure all roles differ
            rotated       = rotate_away_from(available, advocate_model)
            challenger    = explicit_challenger || rotated[0]
            judge         = explicit_judge      || rotate_away_from(rotated, challenger)[0] || rotated[0]

            {
              advocate:   advocate_model,
              challenger: challenger,
              judge:      judge
            }
          end

          def available_models
            providers = extension_providers
            models = []
            providers.each do |provider_name, config|
              next unless config.is_a?(Hash) && config[:enabled]

              default_model = config[:default_model]
              next unless default_model

              models << "#{provider_name}:#{default_model}"
            end
            models
          end

          def extension_providers
            ext = Legion::Settings[:extensions]
            return ext[:llm] if ext.is_a?(Hash) && ext[:llm].is_a?(Hash)

            {}
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'debate.extension_providers')
            {}
          end

          def rotate_away_from(models, exclude_model)
            others = models.reject { |m| m == exclude_model }
            others.empty? ? models : others
          end

          def call_debate_role(prompt:, model:)
            parts    = model.to_s.split(':', 2)
            provider = parts.size == 2 ? parts[0].to_sym : nil
            mdl      = parts.size == 2 ? parts[1] : parts[0]

            opts = {
              message: prompt,
              model:   mdl,
              caller:  { requested_by: { type: :system, identity: 'legion:internal:debate' } }
            }
            opts[:provider] = provider if provider
            log_step_debug(:debate, :role_call, provider: provider || 'default', model: mdl, prompt_chars: prompt.length)

            response = Legion::LLM.chat(**opts)
            log_step_debug(:debate, :role_response, provider: provider || 'default', model: mdl)
            extract_content(response)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.debate.role')
            "[debate role error: #{e.message}]"
          end

          def log_debate_models(rounds, advocate_model, challenger_model, judge_model)
            log_step_debug(
              :debate,
              :models_selected,
              rounds:           rounds,
              advocate_model:   advocate_model,
              challenger_model: challenger_model,
              judge_model:      judge_model
            )
          end

          def run_debate_rounds(rounds:, question:, advocate_model:, challenger_model:, current_advocate:)
            current_challenger = nil
            current_rebuttal = nil
            rounds.times do |i|
              log_step_debug(:debate, :round_start, round: i + 1)
              current_challenger = call_debate_role(
                prompt: format(CHALLENGER_PROMPT, question: question, advocate: current_advocate),
                model:  challenger_model
              )
              current_rebuttal = call_debate_role(
                prompt: format(REBUTTAL_PROMPT, question: question, advocate: current_advocate,
                                                challenger: current_challenger),
                model:  advocate_model
              )
              current_advocate = current_rebuttal
            end
            [current_challenger, current_rebuttal]
          end

          def judge_debate(question:, advocate_text:, current_challenger:, current_rebuttal:, judge_model:)
            log_step_debug(:debate, :judge_start, model: judge_model)
            call_debate_role(
              prompt: format(JUDGE_PROMPT,
                             question:   question,
                             advocate:   advocate_text,
                             challenger: current_challenger || '',
                             rebuttal:   current_rebuttal || ''),
              model:  judge_model
            )
          end

          def debate_metadata(rounds:, advocate_model:, challenger_model:, judge_model:, advocate_text:,
                              current_challenger:, judge_sections:, judge_synthesis:)
            {
              enabled:            true,
              rounds:             rounds,
              advocate_model:     advocate_model,
              challenger_model:   challenger_model,
              judge_model:        judge_model,
              advocate_summary:   truncate_for_metadata(advocate_text),
              challenger_summary: truncate_for_metadata(current_challenger),
              judge_evaluation:   judge_sections[:evaluation],
              judge_confidence:   estimate_judge_confidence(judge_sections[:evaluation] || judge_synthesis)
            }
          end

          def parse_judge_output(content)
            text = content.to_s.strip
            evaluation = text[/\bEvaluation:\s*(.*?)(?:\n\s*Final answer:|\z)/mi, 1]&.strip
            final_answer = text[/\bFinal answer:\s*(.*)\z/mi, 1]&.strip

            {
              evaluation:   truncate_for_metadata(evaluation || text),
              final_answer: final_answer.to_s.empty? ? text : final_answer
            }
          end

          def estimate_judge_confidence(text)
            normalized = text.to_s.downcase
            return 0.4 if normalized.match?(/\b(low confidence|uncertain|unclear|weak evidence)\b/)
            return 0.85 if normalized.match?(/\b(high confidence|stronger|clearly|definitive)\b/)

            0.65
          end

          def truncate_for_metadata(text, limit = 200)
            return nil if text.nil?
            return text if text.length <= limit

            "#{text[0, limit]}..."
          end
        end
      end
    end
  end
end
