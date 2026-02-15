# frozen_string_literal: true

require "json"
require "securerandom"
require "webrick"

class FakeAdapterServlet < WEBrick::HTTPServlet::AbstractServlet
  def initialize(server, adapter)
    super(server)
    @adapter = adapter
  end

  def do_GET(req, res)
    @adapter.route(req, res)
  end

  def do_POST(req, res)
    @adapter.route(req, res)
  end

  def do_DELETE(req, res)
    @adapter.route(req, res)
  end
end

class FakeAdapter
  attr_reader :base_url, :last_publish

  def initialize(shared_secret: "test-secret")
    @shared_secret = shared_secret
    @sessions = {}
    @mutex = Mutex.new
    @last_publish = nil
  end

  def start
    @server = WEBrick::HTTPServer.new(
      Port: 0,
      BindAddress: "127.0.0.1",
      Logger: WEBrick::Log.new($stderr, WEBrick::Log::FATAL),
      AccessLog: []
    )
    @server.mount("/", FakeAdapterServlet, self)

    @thread = Thread.new { @server.start }
    sleep 0.05

    @base_url = "http://127.0.0.1:#{@server.config[:Port]}"
    self
  end

  def stop
    @server&.shutdown
    @thread&.join(1)
  end

  public
  def route(req, res)
    return unauthorized(res) unless authorized?(req)

    case [req.request_method, req.path]
    when ["POST", "/v1/sessions"]
      create_session(req, res)
    else
      if req.request_method == "GET" && req.path.match?(%r{\A/v1/sessions/[^/]+/events\z})
        stream_events(req, res)
      elsif req.request_method == "POST" && req.path.match?(%r{\A/v1/sessions/[^/]+/data\z})
        publish_data(req, res)
      elsif req.request_method == "DELETE" && req.path.match?(%r{\A/v1/sessions/[^/]+\z})
        close_session(req, res)
      else
        json(res, 404, error: "not found")
      end
    end
  end

  def authorized?(req)
    req["Authorization"] == "Bearer #{@shared_secret}"
  end

  def unauthorized(res)
    json(res, 401, error: "missing bearer token")
  end

  def create_session(req, res)
    input = JSON.parse(req.body)
    return json(res, 400, error: "room and identity are required") if input["room"].to_s.empty? || input["identity"].to_s.empty?

    id = SecureRandom.uuid
    @mutex.synchronize { @sessions[id] = true }
    json(res, 201, session_id: id)
  end

  def stream_events(req, res)
    id = req.path.split("/")[3]
    exists = @mutex.synchronize { @sessions.key?(id) }
    return json(res, 404, error: "session not found") unless exists

    event = {
      type: "data",
      session_id: id,
      sender_identity: "alice",
      topic: "chat",
      payload_base64: ["hello-from-server"].pack("m0"),
      at: Time.now.utc.iso8601
    }

    res.status = 200
    res["Content-Type"] = "application/x-ndjson"
    res.body = "#{JSON.generate(event)}\n"
  end

  def publish_data(req, res)
    id = req.path.split("/")[3]
    exists = @mutex.synchronize { @sessions.key?(id) }
    return json(res, 404, error: "session not found") unless exists

    input = JSON.parse(req.body)
    @last_publish = input
    json(res, 202, status: "queued")
  end

  def close_session(req, res)
    id = req.path.split("/")[3]
    removed = @mutex.synchronize { @sessions.delete(id) }
    return json(res, 404, error: "session not found") unless removed

    json(res, 200, status: "closed")
  end

  def json(res, status, payload)
    res.status = status
    res["Content-Type"] = "application/json"
    res.body = JSON.generate(payload)
  end
end
