# frozen_string_literal: true

require "net/http"
require "socket"

require_relative "test_helper"

class AdapterSupervisorTest < Minitest::Test
  def teardown
    LiveKitRealtime::AdapterSupervisor.shutdown_all!
  end

  def test_auto_mode_reuses_healthy_external_adapter
    adapter = FakeAdapter.new(shared_secret: "adapter-secret").start
    supervisor = LiveKitRealtime::AdapterSupervisor.new(
      base_url: adapter.base_url,
      adapter_mode: :auto,
      start_timeout: 1
    )

    started = false
    supervisor.singleton_class.send(:define_method, :ensure_managed_adapter!) { started = true }
    supervisor.ensure_ready!

    refute started
  ensure
    adapter&.stop
  end

  def test_external_mode_never_starts_managed_adapter
    base_url = "http://127.0.0.1:#{next_open_port}"
    supervisor = LiveKitRealtime::AdapterSupervisor.new(
      base_url: base_url,
      adapter_mode: :external,
      start_timeout: 1
    )

    supervisor.singleton_class.send(:define_method, :ensure_managed_adapter!) { raise "unexpected managed startup" }
    supervisor.ensure_ready!
  end

  def test_managed_mode_attempts_start_even_when_health_check_is_true
    base_url = "http://127.0.0.1:#{next_open_port}"
    supervisor = LiveKitRealtime::AdapterSupervisor.new(
      base_url: base_url,
      adapter_mode: :managed,
      start_timeout: 1
    )

    started = false
    supervisor.singleton_class.send(:define_method, :ensure_managed_adapter!) { started = true }
    supervisor.ensure_ready!

    assert started
  end

  def test_auto_mode_starts_managed_adapter_and_shutdown_all_stops_it
    port = next_open_port
    base_url = "http://127.0.0.1:#{port}"

    supervisor = LiveKitRealtime::AdapterSupervisor.new(
      base_url: base_url,
      adapter_mode: :auto,
      start_timeout: 5,
      adapter_bin_path: managed_stub_path
    )

    supervisor.ensure_ready!
    assert health?(base_url), "expected managed adapter to be healthy"

    LiveKitRealtime::AdapterSupervisor.shutdown_all!
    refute health?(base_url), "expected managed adapter to stop after shutdown_all!"
  end

  def test_raises_bootstrap_error_when_build_fails
    base_url = "http://127.0.0.1:#{next_open_port}"
    supervisor = LiveKitRealtime::AdapterSupervisor.new(
      base_url: base_url,
      adapter_mode: :managed,
      start_timeout: 1
    )

    supervisor.singleton_class.send(:define_method, :build_cached_binary!) do
      raise LiveKitRealtime::AdapterBootstrapError, "build boom"
    end

    error = assert_raises(LiveKitRealtime::AdapterBootstrapError) { supervisor.ensure_ready! }
    assert_includes error.message, "build boom"
  end

  def test_raises_bootstrap_error_when_spawn_fails
    base_url = "http://127.0.0.1:#{next_open_port}"
    supervisor = LiveKitRealtime::AdapterSupervisor.new(
      base_url: base_url,
      adapter_mode: :managed,
      start_timeout: 1,
      adapter_bin_path: "/definitely/missing/livekit-adapter"
    )

    error = assert_raises(LiveKitRealtime::AdapterBootstrapError) { supervisor.ensure_ready! }
    assert_includes error.message, "adapter executable not found"
  end

  private

  def managed_stub_path
    File.expand_path("support/managed_adapter_stub.rb", __dir__)
  end

  def health?(base_url)
    uri = URI.join("#{base_url}/", "healthz")
    response = Net::HTTP.get_response(uri)
    response.code.to_i == 200
  rescue StandardError
    false
  end

  def next_open_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end
end
