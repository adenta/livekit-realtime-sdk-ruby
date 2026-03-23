# frozen_string_literal: true

require "digest"
require "fileutils"
require "net/http"
require "open3"
require "rbconfig"
require "tmpdir"
require "uri"

require_relative "version"

module LiveKitRealtime
  class AdapterSupervisor
    DEFAULT_START_TIMEOUT = 20

    @state_mutex = Mutex.new
    @states = {}
    @at_exit_registered = false

    class << self
      def state_for(base_url)
        @state_mutex.synchronize do
          register_at_exit!
          @states[base_url] ||= {}
        end
      end

      def shutdown_all!
        states = @state_mutex.synchronize { @states.values.compact.dup }
        states.each { |state| stop_owned_process!(state) }
      end

      private

      def register_at_exit!
        return if @at_exit_registered

        at_exit { shutdown_all! }
        @at_exit_registered = true
      end

      def stop_owned_process!(state)
        pid = state[:pid]
        return unless pid

        begin
          Process.kill("TERM", pid)
        rescue Errno::ESRCH
          nil
        end

        deadline = Time.now + 5
        while Time.now < deadline
          return clear_state!(state) unless process_alive?(pid)
          sleep 0.05
        end

        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        ensure
          clear_state!(state)
        end
      end

      def clear_state!(state)
        begin
          Process.wait(state[:pid], Process::WNOHANG) if state[:pid]
        rescue Errno::ECHILD, Errno::ESRCH
          nil
        end
        state[:pid] = nil
        state[:log_path] = nil
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end
    end

    def initialize(base_url:, adapter_mode: nil, start_timeout: nil, adapter_bin_path: nil, adapter_log_path: nil)
      @base_url = base_url
      @uri = URI.parse(base_url)
      @adapter_mode = normalize_mode(adapter_mode)
      @start_timeout = normalize_timeout(start_timeout)
      @adapter_bin_path = blank_to_nil(adapter_bin_path)
      @adapter_log_path = blank_to_nil(adapter_log_path)
    end

    def ensure_ready!
      case @adapter_mode
      when :external
        nil
      when :managed
        ensure_managed_adapter!
      when :auto
        return if healthy?

        ensure_managed_adapter!
      else
        raise ArgumentError, "unsupported adapter mode: #{@adapter_mode}"
      end
    end

    private

    def ensure_managed_adapter!
      ensure_local_address!

      state = self.class.state_for(@base_url)
      return if state[:pid] && process_alive?(state[:pid]) && healthy?

      with_start_lock do
        state = self.class.state_for(@base_url)
        if state[:pid] && process_alive?(state[:pid]) && healthy?
          return
        elsif state[:pid] && !process_alive?(state[:pid])
          state[:pid] = nil
        end

        executable = resolve_executable
        spawn_managed_process!(state, executable)
        wait_until_healthy!(state)
      end
    rescue AdapterBootstrapError
      self.class.send(:stop_owned_process!, state) if state
      raise
    rescue StandardError => e
      self.class.send(:stop_owned_process!, state) if state
      raise AdapterBootstrapError, "failed to start LiveKit adapter: #{e.message}"
    end

    def resolve_executable
      return @adapter_bin_path if @adapter_bin_path

      build_cached_binary!
    end

    def build_cached_binary!
      go_dir = File.join(gem_root, "go")
      unless Dir.exist?(go_dir)
        raise AdapterBootstrapError, "Go sources not found at #{go_dir}. Ensure the gem was packaged with go/** files."
      end

      FileUtils.mkdir_p(cache_dir)
      binary = File.join(cache_dir, binary_name)
      if File.exist?(binary) && File.executable?(binary) && !binary_outdated?(binary, go_dir)
        return binary
      end

      stdout, stderr, status = Open3.capture3("go", "build", "-o", binary, "./cmd/livekit-adapter", chdir: go_dir)
      return binary if status.success?

      output = [stdout, stderr].join("\n").strip
      output = "(no output)" if output.empty?
      raise AdapterBootstrapError, "failed to build managed adapter binary with `go build`: #{output}"
    end

    def spawn_managed_process!(state, executable)
      log_path = @adapter_log_path || default_log_path
      FileUtils.mkdir_p(File.dirname(log_path))

      spawn_env = { "ADAPTER_ADDR" => adapter_addr }
      state[:pid] = Process.spawn(
        spawn_env,
        executable,
        out: log_path,
        err: log_path
      )
      state[:log_path] = log_path
    rescue Errno::ENOENT
      raise AdapterBootstrapError, "adapter executable not found: #{executable.inspect}"
    rescue SystemCallError => e
      raise AdapterBootstrapError, "failed to spawn adapter process: #{e.message}"
    end

    def wait_until_healthy!(state)
      deadline = Time.now + @start_timeout
      loop do
        return if healthy?

        unless process_alive?(state[:pid])
          logs = read_recent_logs(state[:log_path])
          raise AdapterBootstrapError, "managed adapter exited before readiness. logs:\n#{logs}"
        end

        break if Time.now >= deadline
        sleep 0.1
      end

      logs = read_recent_logs(state[:log_path])
      raise AdapterBootstrapError, "managed adapter did not become healthy within #{@start_timeout}s. logs:\n#{logs}"
    end

    def read_recent_logs(path)
      return "(no logs)" if path.nil? || !File.exist?(path)

      content = File.read(path)
      return "(no logs)" if content.empty?

      lines = content.lines
      tail = lines.last(40).join
      tail.empty? ? "(no logs)" : tail
    rescue StandardError => e
      "(failed to read logs: #{e.message})"
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def healthy?
      uri = URI.join("#{@base_url}/", "healthz")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 0.5
      http.read_timeout = 0.5
      response = http.get(uri.request_uri)
      response.code.to_i == 200
    rescue StandardError
      false
    end

    def with_start_lock
      FileUtils.mkdir_p(lock_dir)
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |file|
        file.flock(File::LOCK_EX)
        yield
      end
    end

    def lock_path
      digest = Digest::SHA256.hexdigest(@base_url)[0, 16]
      File.join(lock_dir, "adapter_#{digest}.lock")
    end

    def lock_dir
      File.join(Dir.tmpdir, "livekit-realtime-sdk")
    end

    def cache_dir
      File.join(Dir.tmpdir, "livekit-realtime-sdk", "bin", LiveKitRealtime::VERSION)
    end

    def binary_outdated?(binary_path, go_dir)
      binary_mtime = File.mtime(binary_path)
      source_mtime = Dir.glob(File.join(go_dir, "**", "*"))
                       .select { |path| File.file?(path) }
                       .map { |path| File.mtime(path) }
                       .max
      return false if source_mtime.nil?

      source_mtime > binary_mtime
    end

    def binary_name
      host_os = RbConfig::CONFIG["host_os"].to_s
      host_os.match?(/mswin|mingw|cygwin/) ? "livekit-adapter.exe" : "livekit-adapter"
    end

    def default_log_path
      digest = Digest::SHA256.hexdigest(@base_url)[0, 16]
      File.join(Dir.tmpdir, "livekit-realtime-sdk", "logs", "adapter_#{digest}.log")
    end

    def adapter_addr
      "#{@uri.host}:#{@uri.port}"
    end

    def ensure_local_address!
      host = @uri.host.to_s
      return if ["127.0.0.1", "localhost", "::1"].include?(host)

      raise AdapterBootstrapError, "managed adapter mode only supports local adapter URLs, got #{host.inspect}"
    end

    def gem_root
      File.expand_path("../..", __dir__)
    end

    def normalize_mode(value)
      raw = value || ENV["LIVEKIT_REALTIME_ADAPTER_MODE"] || "auto"
      mode = raw.to_s.downcase.strip
      case mode
      when "auto" then :auto
      when "external" then :external
      when "managed" then :managed
      else
        raise ArgumentError, "invalid adapter_mode #{raw.inspect}; expected :auto, :external, or :managed"
      end
    end

    def normalize_timeout(value)
      raw = value || ENV["LIVEKIT_REALTIME_ADAPTER_START_TIMEOUT"] || DEFAULT_START_TIMEOUT
      timeout = Float(raw)
      raise ArgumentError, "adapter_start_timeout must be > 0" if timeout <= 0

      timeout
    rescue ArgumentError, TypeError
      raise ArgumentError, "invalid adapter_start_timeout #{raw.inspect}"
    end

    def blank_to_nil(value)
      return nil if value.nil?

      stripped = value.to_s.strip
      stripped.empty? ? nil : stripped
    end
  end
end
