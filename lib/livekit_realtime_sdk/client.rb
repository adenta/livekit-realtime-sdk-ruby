# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "errors"
require_relative "session"

module LiveKitRealtime
  class Client
    DEFAULT_OPEN_TIMEOUT = 2
    DEFAULT_READ_TIMEOUT = 30

    attr_reader :base_url

    def initialize(base_url: nil, shared_secret: nil, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
      @base_url = normalize_base_url(base_url || ENV["LIVEKIT_REALTIME_ADAPTER_URL"] || ENV["ADAPTER_ADDR"] || "127.0.0.1:8787")
      @shared_secret = shared_secret || ENV["SHARED_SECRET"]
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def create_session(room:, identity:, name: nil)
      payload = { room: room, identity: identity }
      payload[:name] = name if name

      response = json_request(:post, "/v1/sessions", body: payload, expected_statuses: [201])
      Session.new(client: self, session_id: response.fetch("session_id"))
    end

    def publish_data(session_id:, payload:, topic: nil, reliable: true, destination_identities: [])
      json_request(
        :post,
        "/v1/sessions/#{session_id}/data",
        body: {
          payload_base64: [payload].pack("m0"),
          topic: topic,
          reliable: reliable,
          destination_identities: destination_identities
        },
        expected_statuses: [202]
      )
      true
    end

    def close_session(session_id:)
      json_request(:delete, "/v1/sessions/#{session_id}", expected_statuses: [200])
      true
    end

    def stream_events(session_id:, &on_event)
      raise ArgumentError, "block required" unless on_event

      Thread.new do
        run_event_stream(session_id: session_id, &on_event)
      rescue StandardError => e
        on_event.call(type: "error", error: e.message)
      end
    end

    private

    def run_event_stream(session_id:, &on_event)
      uri = uri_for("/v1/sessions/#{session_id}/events")
      request = Net::HTTP::Get.new(uri)
      apply_headers(request)

      with_http(uri) do |http|
        http.request(request) do |response|
          status = response.code.to_i
          raise error_from_response(status, response.body, response["Content-Type"]) unless status == 200

          buffer = +""
          response.read_body do |chunk|
            buffer << chunk
            emit_ndjson_lines(buffer, &on_event)
          end
          emit_ndjson_lines(buffer, &on_event)
        end
      end
    end

    def emit_ndjson_lines(buffer)
      while (newline_index = buffer.index("\n"))
        line = buffer.slice!(0, newline_index + 1).strip
        next if line.empty?

        yield JSON.parse(line, symbolize_names: true)
      end
    end

    def json_request(method, path, body: nil, expected_statuses: [200])
      uri = uri_for(path)
      request = build_request(method, uri, body)

      response = with_http(uri) { |http| http.request(request) }
      status = response.code.to_i

      unless expected_statuses.include?(status)
        raise error_from_response(status, response.body, response["Content-Type"])
      end

      parse_response_body(response.body, response["Content-Type"])
    end

    def with_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout

      yield http
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError, e.message
    rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
      raise ConnectionError, e.message
    end

    def build_request(method, uri, body)
      request = case method
                when :get then Net::HTTP::Get.new(uri)
                when :post then Net::HTTP::Post.new(uri)
                when :delete then Net::HTTP::Delete.new(uri)
                else raise ArgumentError, "unsupported method: #{method}"
                end

      apply_headers(request)
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end

      request
    end

    def apply_headers(request)
      request["Authorization"] = "Bearer #{@shared_secret}" if @shared_secret && !@shared_secret.empty?
      request["Accept"] = "application/json"
    end

    def parse_response_body(body, content_type)
      return {} if body.nil? || body.empty?
      return JSON.parse(body) if content_type.to_s.include?("application/json")

      { "body" => body }
    end

    def error_from_response(status, body, content_type)
      payload = parse_response_body(body, content_type)
      message = payload["error"] || payload["message"] || "request failed"

      case status
      when 400 then BadRequestError.new(status: status, message: message)
      when 401, 403 then AuthError.new(status: status, message: message)
      when 404 then NotFoundError.new(status: status, message: message)
      else AdapterError.new(status: status, message: message)
      end
    end

    def uri_for(path)
      URI.join("#{base_url}/", path.sub(%r{\A/}, ""))
    end

    def normalize_base_url(input)
      return input if input.start_with?("http://", "https://")

      "http://#{input}"
    end
  end
end
