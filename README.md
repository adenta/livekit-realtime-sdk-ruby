# livekit-realtime-sdk (MVP)

This repo contains:

- a Go adapter service for realtime session control against LiveKit
- a Ruby gem client that talks to that adapter over HTTP/NDJSON

## Local setup

1. Copy env file and fill values:

```bash
cp .env.example .env
```

2. Run your Ruby app/tests. The default client mode is `:auto`:

- it first checks `GET /healthz` on `base_url`
- if no adapter is reachable, it starts a managed local adapter process in the background

`LIVEKIT_WS_URL` is preferred for Go adapter config; `LIVEKIT_URL` is accepted as a fallback.

## Manual adapter start (optional)

You can still run adapter manually:

```bash
bin/livekit-adapter
```

or via Foreman:

```bash
bin/dev
```

## Go adapter API

All `/v1/*` endpoints require:

```http
Authorization: Bearer <SHARED_SECRET>
```

- `GET /healthz`
- `POST /v1/sessions`
- `GET /v1/sessions/{session_id}/events` (NDJSON)
- `POST /v1/sessions/{session_id}/data`
- `DELETE /v1/sessions/{session_id}`

## Ruby gem API

```ruby
require "livekit_realtime_sdk"

client = LiveKitRealtime::Client.new(
  base_url: "http://127.0.0.1:8787",
  shared_secret: ENV["SHARED_SECRET"],
  adapter_mode: :auto # :auto (default), :external, :managed
)

session = client.create_session(room: "livekit_realtime_sdk_dev", identity: "ruby-bot")

session.on_data do |event|
  puts "from=#{event.sender_identity} topic=#{event.topic} payload=#{event.payload.inspect}"
end

session.publish_data("hello", topic: "chat")
session.close
```

Adapter options:

- `adapter_mode:`:
  - `:auto` (default): reuse healthy adapter if present, otherwise start managed adapter
  - `:external`: never start adapter automatically
  - `:managed`: always ensure managed adapter process for this Ruby process
- `adapter_start_timeout:` seconds to wait for managed adapter readiness (default `20`)
- `adapter_bin_path:` optional executable/script path to run instead of building `go/cmd/livekit-adapter`
- `adapter_log_path:` optional path for managed adapter stdout/stderr log file

Environment equivalents:

- `LIVEKIT_REALTIME_ADAPTER_MODE` (`auto|external|managed`)
- `LIVEKIT_REALTIME_ADAPTER_START_TIMEOUT`
- `LIVEKIT_REALTIME_ADAPTER_BIN`
- `LIVEKIT_REALTIME_ADAPTER_LOG_PATH`

## Run tests

Ruby:

```bash
rake test
```

Live integration (real LiveKit send/receive):

```bash
LIVEKIT_INTEGRATION=1 ruby -Ilib:test test/livekit_integration_test.rb --verbose
```

Extra live logs during integration test:

```bash
LIVEKIT_INTEGRATION=1 \
LIVEKIT_INTEGRATION_LOG=1 \
ruby -Ilib:test test/livekit_integration_test.rb --verbose
```

Go:

```bash
cd go && go test ./...
```

## Notes

- Current runtime uses `github.com/livekit/server-sdk-go/v2`.
- Managed mode builds adapter binary via local `go build` if no custom `adapter_bin_path` is provided.
- If local Go is older than `go/go.mod`, `GOTOOLCHAIN=auto` may download a newer toolchain automatically.
- TODO(midwest-dads): Ruby client event streaming is currently blocking Net::HTTP + thread-based; planned migration to async/fiber-compatible transport.
