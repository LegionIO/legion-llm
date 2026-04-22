# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'securerandom'

require 'legion/logging/helper'
module Legion
  module LLM
    module Call
      module DaemonClient
        extend Legion::Logging::Helper

        HEALTH_CACHE_TTL = 30
        DEFAULT_TIMEOUT  = 60

        module_function

        # Returns true if the daemon is reachable and healthy.
        # Returns false immediately if daemon_url is nil.
        # Caches a positive health check for HEALTH_CACHE_TTL seconds.
        # An unhealthy result is not cached — rechecks on every call.
        def available?
          return false if daemon_url.nil?

          now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

          return true if @healthy == true && @health_checked_at && (now - @health_checked_at) < HEALTH_CACHE_TTL

          result = check_health
          if result
            @healthy           = true
            @health_checked_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          end
          result
        end

        # POSTs a chat request to the daemon REST API.
        # Returns a status hash based on the HTTP response code.
        def chat(message:, request_id: nil, context: {}, tier_preference: :auto, model: nil, provider: nil)
          request_id ||= SecureRandom.uuid

          body = {
            message:         message,
            request_id:      request_id,
            context:         context,
            tier_preference: tier_preference
          }
          body[:model]    = model    if model
          body[:provider] = provider if provider

          response = http_post('/api/llm/chat', body)
          interpret_response(response)
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.daemon_client.chat', request_id: request_id)
          mark_unhealthy
          { status: :unavailable, error: e.message }
        end

        # Returns the daemon URL from settings, cached after first read.
        # Returns nil if settings are unavailable or the key is missing.
        def daemon_url
          return @daemon_url if defined?(@daemon_url)

          @daemon_url = fetch_daemon_url
        end

        # Clears all cached state. Returns self for chaining.
        def reset!
          remove_instance_variable(:@daemon_url) if defined?(@daemon_url)
          @healthy           = nil
          @health_checked_at = nil
          self
        end

        # GETs /api/health. Returns true on 200, false otherwise.
        # Updates @healthy and @health_checked_at.
        def check_health
          response = http_get('/api/health')
          healthy = response.code == '200'
          @healthy           = healthy
          @health_checked_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          log.info("Daemon health check result=#{healthy ? 'healthy' : 'unhealthy'} url=#{daemon_url}")
          healthy
        rescue StandardError => e
          handle_exception(e, level: :warn)
          mark_unhealthy
          false
        end

        # Marks the daemon as unhealthy and records the timestamp.
        def mark_unhealthy
          log.warn("Daemon marked unhealthy url=#{daemon_url}")
          @healthy           = false
          @health_checked_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        end

        # Builds and sends a GET request. Returns Net::HTTPResponse.
        def http_get(path)
          uri     = URI.parse("#{daemon_url}#{path}")
          http    = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = 2
          http.read_timeout = 2
          request = Net::HTTP::Get.new(uri.request_uri)
          request['Content-Type'] = 'application/json'
          http.request(request)
        end

        # POSTs a conversation-level inference request to the daemon REST API.
        # Accepts a full messages array and optional tool schemas.
        # Returns a status hash with structured inference fields on success.
        def inference(messages:, tools: [], model: nil, provider: nil, caller: nil, conversation_id: nil,
                      timeout: 120)
          body = { messages: messages, tools: tools }
          body[:model]           = model           if model
          body[:provider]        = provider        if provider
          body[:caller]          = caller          if caller
          body[:conversation_id] = conversation_id if conversation_id

          response = http_post('/api/llm/inference', body, timeout: timeout)
          interpret_inference_response(response)
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.daemon_client.inference', conversation_id: conversation_id)
          mark_unhealthy
          { status: :unavailable, error: e.message }
        end

        # Builds and sends a POST request with a JSON body.
        # Returns Net::HTTPResponse.
        # The optional timeout: keyword overrides the default read timeout.
        def http_post(path, body, timeout: DEFAULT_TIMEOUT)
          uri     = URI.parse("#{daemon_url}#{path}")
          http    = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = 5
          http.read_timeout = timeout
          request = Net::HTTP::Post.new(uri.request_uri)
          request['Content-Type'] = 'application/json'
          request.body = Legion::JSON.dump(body)
          http.request(request)
        end

        # Maps an HTTP response to a status hash.
        # Follows the Legion API format: { data: {...} } for success,
        # { error: {...} } for failure.
        def interpret_response(response)
          code   = response.code.to_i
          parsed = safe_parse(response.body)

          case code
          when 200
            { status: :immediate, body: parsed.fetch(:data, parsed) }
          when 201
            { status: :created,   body: parsed.fetch(:data, parsed) }
          when 202
            data = parsed.fetch(:data, {})
            { status: :accepted, request_id: data[:request_id], poll_key: data[:poll_key] }
          when 403
            log.warn("Daemon returned 403 Denied url=#{daemon_url}")
            { status: :denied, error: parsed.fetch(:error, parsed) }
          when 429
            retry_after = extract_retry_after(response, parsed)
            log.warn("Daemon returned 429 RateLimited url=#{daemon_url} retry_after=#{retry_after}")
            { status: :rate_limited, retry_after: retry_after }
          when 503
            { status: :unavailable }
          else
            { status: :error, code: code, body: parsed }
          end
        end

        # ── private helpers ────────────────────────────────────────────────

        def fetch_daemon_url
          settings = Legion::LLM.settings
          return nil unless settings.is_a?(Hash)

          daemon = settings[:daemon] || settings['daemon']
          return nil unless daemon.is_a?(Hash)
          return nil if daemon[:enabled] == false || daemon['enabled'] == false

          daemon[:url] || daemon['url']
        rescue StandardError => e
          handle_exception(e, level: :warn)
          nil
        end

        def safe_parse(body)
          return {} if body.nil? || body.strip.empty?

          ::JSON.parse(body, symbolize_names: true)
        rescue ::JSON::ParserError => e
          handle_exception(e, level: :debug)
          {}
        end

        def extract_retry_after(response, parsed)
          from_body = parsed.dig(:error, :retry_after) || parsed[:retry_after]
          return from_body.to_i if from_body

          header = response['Retry-After']
          return header.to_i if header

          0
        end

        # Maps an HTTP response from /api/llm/inference to a structured status hash.
        # On 200 returns :ok with structured inference fields extracted from the body.
        # All other codes follow the same error handling as interpret_response.
        def interpret_inference_response(response)
          code   = response.code.to_i
          parsed = safe_parse(response.body)

          if code == 200
            data = parsed.fetch(:data, parsed)
            return {
              status: :ok,
              data:   {
                request_id:    data[:request_id],
                content:       data[:content],
                tool_calls:    data[:tool_calls] || [],
                stop_reason:   data[:stop_reason],
                model:         data[:model],
                input_tokens:  data[:input_tokens],
                output_tokens: data[:output_tokens]
              }
            }
          end

          case code
          when 403
            log.warn("Daemon returned 403 Denied url=#{daemon_url}")
            { status: :denied, error: parsed.fetch(:error, parsed) }
          when 429
            retry_after = extract_retry_after(response, parsed)
            log.warn("Daemon returned 429 RateLimited url=#{daemon_url} retry_after=#{retry_after}")
            { status: :rate_limited, retry_after: retry_after }
          when 503
            { status: :unavailable }
          else
            { status: :error, code: code, body: parsed }
          end
        end

        private_class_method :fetch_daemon_url, :safe_parse, :extract_retry_after, :interpret_inference_response
      end
    end
  end
end
