# frozen_string_literal: true

require "socket"

require_relative "test_helper"

class ClientTest < Minitest::Test
  def setup
    @secret = "adapter-secret"
    @adapter = FakeAdapter.new(shared_secret: @secret).start
    @client = LiveKitRealtime::Client.new(base_url: @adapter.base_url, shared_secret: @secret)
  end

  def teardown
    @adapter.stop
  end

  def test_create_publish_stream_and_close
    session = @client.create_session(room: "room-1", identity: "bot")

    received = Queue.new
    session.on_data { |evt| received << evt }

    session.publish_data("hello", topic: "chat", destination_identities: ["alice"])
    assert_equal "chat", @adapter.last_publish["topic"]
    assert_equal ["alice"], @adapter.last_publish["destination_identities"]

    event = Timeout.timeout(2) { received.pop }
    assert_equal "alice", event.sender_identity
    assert_equal "chat", event.topic
    assert_equal "hello-from-server", event.payload

    assert session.close
    assert session.closed?
    assert_raises(LiveKitRealtime::Error) { session.on_data { |_evt| nil } }
  end

  def test_auth_error_mapping
    bad_client = LiveKitRealtime::Client.new(base_url: @adapter.base_url, shared_secret: "wrong")

    error = assert_raises(LiveKitRealtime::AuthError) do
      bad_client.create_session(room: "room-1", identity: "bot")
    end

    assert_equal 401, error.status
  end

  def test_not_found_error_mapping
    error = assert_raises(LiveKitRealtime::NotFoundError) do
      @client.publish_data(session_id: "missing", payload: "x")
    end

    assert_equal 404, error.status
  end

  def test_external_mode_does_not_autostart_when_unreachable
    addr = "127.0.0.1:#{next_open_port}"
    client = LiveKitRealtime::Client.new(
      base_url: "http://#{addr}",
      shared_secret: @secret,
      adapter_mode: :external,
      open_timeout: 0.2,
      read_timeout: 0.2
    )

    assert_raises(LiveKitRealtime::ConnectionError) do
      client.create_session(room: "room-1", identity: "bot")
    end
  end

  def test_managed_mode_invokes_supervisor_before_request
    calls = 0
    supervisor = Object.new
    supervisor.define_singleton_method(:ensure_ready!) { calls += 1 }

    client = LiveKitRealtime::Client.new(base_url: @adapter.base_url, shared_secret: @secret, adapter_mode: :managed)
    client.instance_variable_set(:@adapter_supervisor, supervisor)

    client.create_session(room: "room-1", identity: "bot")
    assert_equal 1, calls
  end

  private

  def next_open_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end
end
