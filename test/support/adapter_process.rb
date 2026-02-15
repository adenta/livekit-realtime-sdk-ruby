# frozen_string_literal: true

require "fileutils"
require "net/http"
require "socket"
require "timeout"
require "uri"

class AdapterProcess
  attr_reader :addr, :base_url, :log_path

  def initialize(env: {}, stream_logs: false, log_prefix: "[adapter]")
    @extra_env = env
    @stream_logs = stream_logs
    @log_prefix = log_prefix
    @pid = nil
    @addr = nil
    @base_url = nil
    @stream_thread = nil
    @stop_streaming = false
  end

  def start!
    port = next_open_port
    @addr = "127.0.0.1:#{port}"
    @base_url = "http://#{@addr}"

    root = File.expand_path("../..", __dir__)
    go_dir = File.join(root, "go")
    FileUtils.mkdir_p(File.join(root, "tmp"))
    @log_path = File.join(root, "tmp", "adapter_integration.log")

    spawn_env = @extra_env.merge("ADAPTER_ADDR" => @addr)
    @pid = Process.spawn(
      spawn_env,
      "go", "run", "./cmd/livekit-adapter",
      chdir: go_dir,
      out: @log_path,
      err: @log_path
    )

    start_log_stream! if @stream_logs
    wait_for_health!
  end

  def stop!
    return unless @pid

    begin
      Process.kill("TERM", @pid)
      Timeout.timeout(5) { Process.wait(@pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    rescue Timeout::Error
      begin
        Process.kill("KILL", @pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.wait(@pid)
      rescue Errno::ECHILD
        nil
      end
    ensure
      stop_log_stream!
      @pid = nil
    end
  end

  private

  def start_log_stream!
    @stop_streaming = false
    @stream_thread = Thread.new do
      last_offset = 0
      while !@stop_streaming
        last_offset = print_new_logs(last_offset)
        sleep 0.2
      end
      print_new_logs(last_offset)
    end
  end

  def stop_log_stream!
    return unless @stream_thread

    @stop_streaming = true
    @stream_thread.join(1)
    @stream_thread = nil
  end

  def print_new_logs(offset)
    return offset unless @log_path && File.exist?(@log_path)

    current_offset = offset
    File.open(@log_path, "r") do |f|
      f.seek(offset)
      new_data = f.read
      current_offset = f.pos
      if new_data && !new_data.empty?
        new_data.each_line do |line|
          $stdout.puts "#{@log_prefix} #{line.rstrip}"
        end
        $stdout.flush
      end
    end

    current_offset
  end

  def wait_for_health!
    uri = URI("#{@base_url}/healthz")
    deadline = Time.now + 20

    loop do
      begin
        response = Net::HTTP.get_response(uri)
        return if response.code.to_i == 200
      rescue SocketError, SystemCallError
        nil
      end

      break if Time.now >= deadline

      sleep 0.2
    end

    logs = if @log_path && File.exist?(@log_path)
             File.read(@log_path)
           else
             "(no logs)"
           end
    raise "adapter failed to start on #{@addr}. logs:\n#{logs}"
  end

  def next_open_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end
end
