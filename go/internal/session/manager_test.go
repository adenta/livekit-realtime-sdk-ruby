package session

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/midwest-dads/livekit-realtime-sdk/go/internal/engine"
)

type fakeConnector struct {
	session   *fakeSession
	callbacks engine.Callbacks
}

type fakeSession struct {
	published []engine.PublishDataRequest
	closed    bool
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
	s.closed = true
	return nil
}

func TestManagerLifecycleAndEvents(t *testing.T) {
	connector := &fakeConnector{}
	manager := NewManager(connector)

	sessionID, err := manager.Create(context.Background(), CreateInput{
		WSURL:     "wss://example.livekit.cloud",
		APIKey:    "key",
		APISecret: "secret",
		Room:      "room-a",
		Identity:  "bot-1",
	})
	if err != nil {
		t.Fatalf("create session: %v", err)
	}

	events, unsubscribe, err := manager.Subscribe(sessionID)
	if err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	defer unsubscribe()

	connector.callbacks.OnData(engine.DataEvent{
		Payload:        []byte("hello"),
		Topic:          "chat",
		SenderIdentity: "remote-user",
	})

	select {
	case evt := <-events:
		if evt.Type != "data" {
			t.Fatalf("expected data event, got %q", evt.Type)
		}
		if evt.Topic != "chat" {
			t.Fatalf("expected topic chat, got %q", evt.Topic)
		}
		if evt.SenderIdentity != "remote-user" {
			t.Fatalf("expected sender remote-user, got %q", evt.SenderIdentity)
		}
		if evt.PayloadBase64 == "" {
			t.Fatal("expected encoded payload")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for data event")
	}

	err = manager.PublishData(context.Background(), sessionID, PublishInput{
		Payload:               []byte("hi-back"),
		Topic:                 "chat",
		Reliable:              true,
		DestinationIdentities: []string{"remote-user"},
	})
	if err != nil {
		t.Fatalf("publish data: %v", err)
	}

	if len(connector.session.published) != 1 {
		t.Fatalf("expected one published packet, got %d", len(connector.session.published))
	}

	if err := manager.Close(sessionID); err != nil {
		t.Fatalf("close session: %v", err)
	}
	if !connector.session.closed {
		t.Fatal("expected underlying session to be closed")
	}

	_, _, err = manager.Subscribe(sessionID)
	if !errors.Is(err, ErrSessionNotFound) {
		t.Fatalf("expected ErrSessionNotFound after close, got %v", err)
	}
}

func TestManagerAutoCloseOnDisconnectCallback(t *testing.T) {
	connector := &fakeConnector{}
	manager := NewManager(connector)

	sessionID, err := manager.Create(context.Background(), CreateInput{
		WSURL:     "wss://example.livekit.cloud",
		APIKey:    "key",
		APISecret: "secret",
		Room:      "room-a",
		Identity:  "bot-1",
	})
	if err != nil {
		t.Fatalf("create session: %v", err)
	}

	connector.callbacks.OnDisconnected("requested")

	_, _, err = manager.Subscribe(sessionID)
	if !errors.Is(err, ErrSessionNotFound) {
		t.Fatalf("expected ErrSessionNotFound after disconnect callback, got %v", err)
	}
}
