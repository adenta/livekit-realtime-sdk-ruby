#!/usr/bin/env ruby
# frozen_string_literal: true

require "webrick"

addr = ENV.fetch("ADAPTER_ADDR", "127.0.0.1:8787")
host, port_str = addr.split(":", 2)
port = Integer(port_str)

server = WEBrick::HTTPServer.new(
  Port: port,
  BindAddress: host,
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::FATAL),
  AccessLog: []
)

server.mount_proc("/healthz") do |_req, res|
  res.status = 200
  res["Content-Type"] = "application/json"
  res.body = '{"status":"ok"}'
end

trap("TERM") { server.shutdown }
trap("INT") { server.shutdown }

server.start
