# frozen_string_literal: true

require "securerandom"
require "time"

require_relative "test_helper"
require_relative "support/adapter_process"

class LiveKitIntegrationTest < Minitest::Test
  REQUIRED_ENV = %w[
    LIVEKIT_API_KEY
    LIVEKIT_API_SECRET
    SHARED_SECRET
  ].freeze

  def setup
    skip "set LIVEKIT_INTEGRATION=1 to run live integration tests" unless ENV["LIVEKIT_INTEGRATION"] == "1"

    missing = missing_env
    skip "missing env: #{missing.join(', ')}" unless missing.empty?

    livekit_url = ENV["LIVEKIT_WS_URL"] || ENV["LIVEKIT_URL"]
    skip "missing env: LIVEKIT_WS_URL or LIVEKIT_URL" if livekit_url.to_s.empty?

    room_prefix = ENV["LIVEKIT_TEST_ROOM"].to_s
    room_prefix = "livekit_realtime_sdk_dev" if room_prefix.empty?
    @log_enabled = ENV.fetch("LIVEKIT_INTEGRATION_LOG", "1") == "1"
    $stdout.sync = true if @log_enabled

    log "starting integration setup"

    @adapter = AdapterProcess.new(
      env: {
        "LIVEKIT_WS_URL" => livekit_url,
        "LIVEKIT_API_KEY" => ENV.fetch("LIVEKIT_API_KEY"),
        "LIVEKIT_API_SECRET" => ENV.fetch("LIVEKIT_API_SECRET"),
        "SHARED_SECRET" => ENV.fetch("SHARED_SECRET")
      },
      stream_logs: ENV["LIVEKIT_INTEGRATION_ADAPTER_LOGS"] == "1"
    )
    log "starting adapter process"
    @adapter.start!
    log "adapter ready at #{@adapter.base_url}"

    @client = LiveKitRealtime::Client.new(
      base_url: @adapter.base_url,
      shared_secret: ENV.fetch("SHARED_SECRET"),
      open_timeout: 5,
      read_timeout: 120
    )

    @room = "#{room_prefix}_#{SecureRandom.hex(4)}"
    log "test room #{@room}"
  end

  def teardown
    log "teardown: closing sender session" if @sender
    @sender&.close
    log "teardown: closing receiver session" if @receiver
    @receiver&.close
    log "teardown: stopping adapter process"
    @adapter&.stop!
    log "teardown complete"
  end

  def test_send_and_receive_room_data
    receiver_identity = "ruby-recv-#{SecureRandom.hex(4)}"
    sender_identity = "ruby-send-#{SecureRandom.hex(4)}"
    expected_topic = "integration-#{SecureRandom.hex(4)}"
    expected_payload = "hello-livekit-#{SecureRandom.hex(8)}"

    log "creating receiver session identity=#{receiver_identity}"
    @receiver = @client.create_session(room: @room, identity: receiver_identity, name: "Receiver")
    log "receiver session created id=#{@receiver.session_id}"
    log "creating sender session identity=#{sender_identity}"
    @sender = @client.create_session(room: @room, identity: sender_identity, name: "Sender")
    log "sender session created id=#{@sender.session_id}"

    received = Queue.new
    log "subscribing receiver to data events"
    @receiver.on_data do |event|
      log "received event type=data sender=#{event.sender_identity} topic=#{event.topic} payload=#{event.payload.inspect}"
      if event.topic == expected_topic && event.payload == expected_payload
        received << event
      end
    end

    received_event = nil
    5.times do
      attempt = _1 + 1
      log "publish attempt #{attempt}: topic=#{expected_topic} payload=#{expected_payload.inspect}"
      @sender.publish_data(
        expected_payload,
        topic: expected_topic,
        destination_identities: [receiver_identity],
        reliable: true
      )
      log "publish attempt #{attempt}: sent"

      begin
        received_event = Timeout.timeout(4) { received.pop }
        log "matching event received on attempt #{attempt}"
        break
      rescue Timeout::Error
        log "no matching event yet on attempt #{attempt}"
      end
    end

    refute_nil received_event, "timed out waiting for data event (adapter logs: #{@adapter.log_path})"
    assert_equal sender_identity, received_event.sender_identity
    assert_equal expected_topic, received_event.topic
    assert_equal expected_payload, received_event.payload
    log "assertions passed"
  end

  private

  def missing_env
    REQUIRED_ENV.select { |key| ENV[key].to_s.empty? }
  end

  def log(message)
    return unless @log_enabled

    puts "[integration] #{Time.now.utc.iso8601} #{message}"
  end
end
