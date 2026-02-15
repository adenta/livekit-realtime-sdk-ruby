package engine

import "context"

type DataEvent struct {
	Payload        []byte
	Topic          string
	SenderIdentity string
}

type Callbacks struct {
	OnData         func(evt DataEvent)
	OnDisconnected func(reason string)
}

type ConnectParams struct {
	WSURL     string
	APIKey    string
	APISecret string
	Room      string
	Identity  string
	Name      string
}

type PublishDataRequest struct {
	Payload               []byte
	Topic                 string
	Reliable              bool
	DestinationIdentities []string
}

type Session interface {
	PublishData(ctx context.Context, req PublishDataRequest) error
	Close() error
}

type Connector interface {
	Connect(ctx context.Context, params ConnectParams, callbacks Callbacks) (Session, error)
}
