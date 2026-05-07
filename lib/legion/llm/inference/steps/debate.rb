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
            Your task is to synthesize the strongest arguments from both sides and produce the most
            accurate, balanced, and complete answer possible.

            Original question/request:
            %<question>s

            Advocate's position:
            %<advocate>s

            Challenger's critique:
            %<challenger>s

            Advocate's rebuttal:
            %<rebuttal>s

            Synthesize these perspectives into a final, authoritative answer. Incorporate valid
            points from the critique while preserving what the advocate got right. Be direct and
            definitive.
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

            log_step_debug(:debate, :start)
            debate_result = run_debate(@raw_response, @request)
            unless debate_result
              log_step_debug(:debate, :skipped, reason: :no_result)
              return
            end

            @raw_response = debate_result[:synthetic_response]
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
            explicit = Legion::LLM::Settings.config_value(request.extra, :debate)
            return explicit unless explicit.nil?

            gaia_trigger = gaia_debate_trigger?(@enrichments)
            return true if gaia_trigger

            settings_value(:debate, :enabled) == true
          end

          def gaia_debate_trigger?(enrichments)
            return false unless debate_setting(:gaia_auto_trigger) == true

            advisory = Legion::LLM::Settings.config_value(enrichments&.fetch('gaia:advisory', nil), :data)
            return false unless advisory.is_a?(Hash)

            Legion::LLM::Settings.config_value(advisory, :high_stakes) == true || Legion::LLM::Settings.config_value(advisory, :debate_recommended) == true
          end

          def run_debate(advocate_response, request)
            rounds      = resolve_debate_rounds(request)
            question    = extract_question(request)
            advocate_text = extract_content(advocate_response)

            models = select_debate_models(request)
            @warnings << models[:warning] if models[:warning]

            advocate_model    = models[:advocate]
            challenger_model  = models[:challenger]
            judge_model       = models[:judge]

            current_advocate = advocate_text
            current_challenger = nil
            current_rebuttal   = nil
            log_step_debug(
              :debate,
              :models_selected,
              rounds:           rounds,
              advocate_model:   advocate_model,
              challenger_model: challenger_model,
              judge_model:      judge_model
            )

            rounds.times do |i|
              log_step_debug(:debate, :round_start, round: i + 1)
              current_challenger = call_debate_role(
                prompt: format(CHALLENGER_PROMPT, question: question, advocate: current_advocate),
                model:  challenger_model
              )
              current_rebuttal = call_debate_role(
                prompt: format(REBUTTAL_PROMPT, question:   question,
                                                advocate:   current_advocate,
                                                challenger: current_challenger),
                model:  advocate_model
              )
              current_advocate = current_rebuttal
            end

            log_step_debug(:debate, :judge_start, model: judge_model)
            judge_synthesis = call_debate_role(
              prompt: format(JUDGE_PROMPT,
                             question:   question,
                             advocate:   advocate_text,
                             challenger: current_challenger || '',
                             rebuttal:   current_rebuttal || ''),
              model:  judge_model
            )

            synthetic_response = SyntheticResponse.new(judge_synthesis)

            {
              synthetic_response: synthetic_response,
              rounds:             rounds,
              metadata:           {
                enabled:            true,
                rounds:             rounds,
                advocate_model:     advocate_model,
                challenger_model:   challenger_model,
                judge_model:        judge_model,
                advocate_summary:   truncate_for_metadata(advocate_text),
                challenger_summary: truncate_for_metadata(current_challenger),
                judge_confidence:   nil
              }
            }
          end

          SyntheticResponse = Struct.new(:content) do
            def input_tokens  = nil
            def output_tokens = nil
          end
          private_constant :SyntheticResponse

          private

          def debate_settings
            @debate_settings ||= settings_value(:debate) || {}
          end

          def debate_setting(key, default = nil)
            Legion::LLM::Settings.config_value(debate_settings, key, default)
          end

          def settings_value(*keys, default: nil)
            Legion::LLM::Settings.value(*keys, default: default)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.steps.debate.settings', keys: keys)
            default
          end

          def resolve_debate_rounds(request)
            requested = Legion::LLM::Settings.config_value(request.extra, :debate_rounds)
            default   = debate_setting(:default_rounds, 1)
            max       = debate_setting(:max_rounds, 3)

            rounds = requested ? requested.to_i : default.to_i
            rounds = 1 if rounds < 1
            [rounds, max.to_i].min
          end

          def extract_question(request)
            request.messages.select { |m| m[:role] == :user }
                            .last&.dig(:content) || ''
          end

          def extract_content(response)
            if response.respond_to?(:content)
              response.content.to_s
            elsif response.is_a?(Hash)
              (response[:content] || response['content']).to_s
            else
              response.to_s
            end
          end

          def select_debate_models(request)
            explicit_advocate   = debate_setting(:advocate_model)
            explicit_challenger = debate_setting(:challenger_model)
            explicit_judge      = debate_setting(:judge_model)

            request_model    = @resolved_model || Legion::LLM::Settings.config_value(request.routing, :model) || settings_value(:default_model)
            request_provider = @resolved_provider || Legion::LLM::Settings.config_value(request.routing, :provider) || settings_value(:default_provider)

            advocate_model = explicit_advocate || "#{request_provider}:#{request_model}"

            if explicit_challenger && explicit_judge
              return {
                advocate:   advocate_model,
                challenger: explicit_challenger,
                judge:      explicit_judge
              }
            end

            available = available_models
            if available.size < 2
              warning = 'debate: fewer than 2 models available — using same model for all roles (training bias not avoided)'
              fallback = available.first || advocate_model
              return {
                advocate:   advocate_model,
                challenger: explicit_challenger || fallback,
                judge:      explicit_judge      || fallback,
                warning:    warning
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
              next unless config.is_a?(Hash) && Legion::LLM::Settings.config_value(config, :enabled)

              default_model = Legion::LLM::Settings.config_value(config, :default_model)
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
            handle_exception(e, level: :debug, handled: true, operation: 'debate.extension_providers')
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

            opts = { message: prompt, model: mdl }
            opts[:provider] = provider if provider
            log_step_debug(:debate, :role_call, provider: provider || 'default', model: mdl, prompt_chars: prompt.length)

            response = Legion::LLM.chat_direct(**opts)
            log_step_debug(:debate, :role_response, provider: provider || 'default', model: mdl)
            extract_content(response)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.debate.role')
            "[debate role error: #{e.message}]"
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
