package session

import (
	"context"
	"encoding/base64"
	"errors"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/midwest-dads/livekit-realtime-sdk/go/internal/engine"
)

var ErrSessionNotFound = errors.New("session not found")

type Event struct {
	Type           string    `json:"type"`
	SessionID      string    `json:"session_id,omitempty"`
	SenderIdentity string    `json:"sender_identity,omitempty"`
	Topic          string    `json:"topic,omitempty"`
	PayloadBase64  string    `json:"payload_base64,omitempty"`
	Reason         string    `json:"reason,omitempty"`
	At             time.Time `json:"at"`
}

type CreateInput struct {
	WSURL     string
	APIKey    string
	APISecret string
	Room      string
	Identity  string
	Name      string
}

type PublishInput struct {
	Payload               []byte
	Topic                 string
	Reliable              bool
	DestinationIdentities []string
}

type Manager struct {
	connector engine.Connector

	mu       sync.RWMutex
	sessions map[string]*managedSession
}

type managedSession struct {
	id        string
	handle    engine.Session
	closeOnce sync.Once

	mu          sync.RWMutex
	subscribers map[chan Event]struct{}
}

func NewManager(connector engine.Connector) *Manager {
	return &Manager{
		connector: connector,
		sessions:  make(map[string]*managedSession),
	}
}

func (m *Manager) Create(ctx context.Context, input CreateInput) (string, error) {
	id := uuid.NewString()
	ms := &managedSession{
		id:          id,
		subscribers: make(map[chan Event]struct{}),
	}

	handle, err := m.connector.Connect(ctx, engine.ConnectParams{
		WSURL:     input.WSURL,
		APIKey:    input.APIKey,
		APISecret: input.APISecret,
		Room:      input.Room,
		Identity:  input.Identity,
		Name:      input.Name,
	}, engine.Callbacks{
		OnData: func(evt engine.DataEvent) {
			ms.publish(Event{
				Type:           "data",
				SessionID:      id,
				SenderIdentity: evt.SenderIdentity,
				Topic:          evt.Topic,
				PayloadBase64:  base64.StdEncoding.EncodeToString(evt.Payload),
				At:             time.Now().UTC(),
			})
		},
		OnDisconnected: func(reason string) {
			ms.publish(Event{
				Type:      "disconnected",
				SessionID: id,
				Reason:    reason,
				At:        time.Now().UTC(),
			})
			_ = m.Close(id)
		},
	})
	if err != nil {
		return "", err
	}
	ms.handle = handle

	m.mu.Lock()
	m.sessions[id] = ms
	m.mu.Unlock()

	return id, nil
}

func (m *Manager) PublishData(ctx context.Context, id string, input PublishInput) error {
	ms, err := m.get(id)
	if err != nil {
		return err
	}

	return ms.handle.PublishData(ctx, engine.PublishDataRequest{
		Payload:               input.Payload,
		Topic:                 input.Topic,
		Reliable:              input.Reliable,
		DestinationIdentities: input.DestinationIdentities,
	})
}

func (m *Manager) Subscribe(id string) (<-chan Event, func(), error) {
	ms, err := m.get(id)
	if err != nil {
		return nil, nil, err
	}

	ch := make(chan Event, 64)
	ms.mu.Lock()
	ms.subscribers[ch] = struct{}{}
	ms.mu.Unlock()

	unsubscribe := func() {
		ms.mu.Lock()
		if _, ok := ms.subscribers[ch]; ok {
			delete(ms.subscribers, ch)
			close(ch)
		}
		ms.mu.Unlock()
	}

	return ch, unsubscribe, nil
}

func (m *Manager) Close(id string) error {
	m.mu.Lock()
	ms, ok := m.sessions[id]
	if ok {
		delete(m.sessions, id)
	}
	m.mu.Unlock()

	if !ok {
		return ErrSessionNotFound
	}

	ms.closeOnce.Do(func() {
		_ = ms.handle.Close()
		ms.closeSubscribers()
	})
	return nil
}

func (m *Manager) get(id string) (*managedSession, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	ms, ok := m.sessions[id]
	if !ok {
		return nil, ErrSessionNotFound
	}
	return ms, nil
}

func (s *managedSession) publish(evt Event) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for ch := range s.subscribers {
		select {
		case ch <- evt:
		default:
		}
	}
}

func (s *managedSession) closeSubscribers() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for ch := range s.subscribers {
		close(ch)
		delete(s.subscribers, ch)
	}
}
