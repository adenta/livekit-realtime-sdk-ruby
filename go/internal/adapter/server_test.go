package adapter

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/midwest-dads/livekit-realtime-sdk/go/internal/config"
	"github.com/midwest-dads/livekit-realtime-sdk/go/internal/engine"
	"github.com/midwest-dads/livekit-realtime-sdk/go/internal/session"
)

type fakeConnector struct {
	session   *fakeSession
	callbacks engine.Callbacks
}

type fakeSession struct {
	published []engine.PublishDataRequest
}

func (c *fakeConnector) Connect(_ context.Context, _ engine.ConnectParams, cb engine.Callbacks) (engine.Session, error) {
	if c.session == nil {
		c.session = &fakeSession{}
	}
	c.callbacks = cb
	return c.session, nil
}

func (s *fakeSession) PublishData(_ context.Context, req engine.PublishDataRequest) error {
	s.published = append(s.published, req)
	return nil
}

func (s *fakeSession) Close() error {
	return nil
}

func TestAuthRequired(t *testing.T) {
	connector := &fakeConnector{}
	manager := session.NewManager(connector)
	cfg := &config.Config{
		AdapterAddr:      "127.0.0.1:0",
		LiveKitWSURL:     "wss://example.livekit.cloud",
		LiveKitAPIKey:    "key",
		LiveKitAPISecret: "secret",
		SharedSecret:     "topsecret",
	}
	srv := New(cfg, manager, slog.New(slog.NewTextHandler(io.Discard, nil)))
	testSrv := httptest.NewServer(srv.Handler())
	defer testSrv.Close()

	resp, err := http.Post(testSrv.URL+"/v1/sessions", "application/json", strings.NewReader(`{"room":"r1","identity":"bot"}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

func TestCreatePublishAndStreamEvents(t *testing.T) {
	connector := &fakeConnector{}
	manager := session.NewManager(connector)
	cfg := &config.Config{
		AdapterAddr:      "127.0.0.1:0",
		LiveKitWSURL:     "wss://example.livekit.cloud",
		LiveKitAPIKey:    "key",
		LiveKitAPISecret: "secret",
		SharedSecret:     "topsecret",
	}
	srv := New(cfg, manager, slog.New(slog.NewTextHandler(io.Discard, nil)))
	testSrv := httptest.NewServer(srv.Handler())
	defer testSrv.Close()

	sessionID := createSession(t, testSrv.URL)

	client := &http.Client{Timeout: 3 * time.Second}
	streamReq, _ := http.NewRequest(http.MethodGet, testSrv.URL+"/v1/sessions/"+sessionID+"/events", nil)
	streamReq.Header.Set("Authorization", "Bearer topsecret")
	streamResp, err := client.Do(streamReq)
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	defer streamResp.Body.Close()

	if streamResp.StatusCode != http.StatusOK {
		t.Fatalf("expected stream 200, got %d", streamResp.StatusCode)
	}

	connector.callbacks.OnData(engine.DataEvent{
		Payload:        []byte("hello"),
		Topic:          "chat",
		SenderIdentity: "remote-user",
	})

	scanner := bufio.NewScanner(streamResp.Body)
	if !scanner.Scan() {
		t.Fatalf("expected one event line, err=%v", scanner.Err())
	}

	var evt map[string]any
	if err := json.Unmarshal(scanner.Bytes(), &evt); err != nil {
		t.Fatalf("parse event json: %v", err)
	}

	if evt["type"] != "data" {
		t.Fatalf("expected data event, got %v", evt["type"])
	}
	if evt["topic"] != "chat" {
		t.Fatalf("expected chat topic, got %v", evt["topic"])
	}

	publishReq := map[string]any{
		"payload_base64": base64.StdEncoding.EncodeToString([]byte("from-ruby")),
		"topic":          "chat",
		"reliable":       true,
	}
	buf, _ := json.Marshal(publishReq)
	req, _ := http.NewRequest(http.MethodPost, testSrv.URL+"/v1/sessions/"+sessionID+"/data", strings.NewReader(string(buf)))
	req.Header.Set("Authorization", "Bearer topsecret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("publish request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("expected 202, got %d", resp.StatusCode)
	}
	if len(connector.session.published) != 1 {
		t.Fatalf("expected one published packet, got %d", len(connector.session.published))
	}
}

func createSession(t *testing.T, baseURL string) string {
	t.Helper()
	payload := `{"room":"r1","identity":"bot"}`
	req, _ := http.NewRequest(http.MethodPost, baseURL+"/v1/sessions", strings.NewReader(payload))
	req.Header.Set("Authorization", "Bearer topsecret")
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("create session request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("expected 201, got %d", resp.StatusCode)
	}

	var out map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if out["session_id"] == "" {
		t.Fatal("missing session_id in response")
	}
	return out["session_id"]
}
