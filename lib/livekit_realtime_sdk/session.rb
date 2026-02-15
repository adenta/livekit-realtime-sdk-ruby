# frozen_string_literal: true

require "base64"
require "time"

module LiveKitRealtime
  DataEvent = Struct.new(
    :session_id,
    :sender_identity,
    :topic,
    :payload,
    :payload_base64,
    :at,
    keyword_init: true
  )

  class Session
    attr_reader :session_id

    def initialize(client:, session_id:)
      @client = client
      @session_id = session_id
      @callbacks = []
      @mutex = Mutex.new
      @stream_thread = nil
      @closed = false
    end

    def on_data(&block)
      raise ArgumentError, "block required" unless block
      raise LiveKitRealtime::Error, "session closed" if closed?

      @mutex.synchronize { @callbacks << block }
      ensure_streaming
      self
    end

    def publish_data(payload, topic: nil, reliable: true, destination_identities: [])
      raise LiveKitRealtime::Error, "session closed" if closed?

      data = payload.is_a?(String) ? payload.b : payload.to_s.b
      @client.publish_data(
        session_id: @session_id,
        payload: data,
        topic: topic,
        reliable: reliable,
        destination_identities: destination_identities
      )
      true
    end

    def close
      return true if closed?

      @client.close_session(session_id: @session_id)
      @closed = true
      @stream_thread&.join(1)
      @stream_thread&.kill if @stream_thread&.alive?
      true
    end

    def closed?
      @closed
    end

    private

    def ensure_streaming
      return if @stream_thread&.alive?

      @stream_thread = @client.stream_events(session_id: @session_id) do |event|
        handle_event(event)
      end
    end

    def handle_event(event)
      return unless event[:type] == "data"

      payload_base64 = event[:payload_base64].to_s
      data_event = DataEvent.new(
        session_id: event[:session_id],
        sender_identity: event[:sender_identity],
        topic: event[:topic],
        payload: Base64.decode64(payload_base64),
        payload_base64: payload_base64,
        at: parse_time(event[:at])
      )

      callbacks = @mutex.synchronize { @callbacks.dup }
      callbacks.each { |callback| callback.call(data_event) }
    end

    def parse_time(value)
      return nil if value.nil? || value.empty?

      Time.parse(value)
    rescue ArgumentError
      nil
    end
  end
end
