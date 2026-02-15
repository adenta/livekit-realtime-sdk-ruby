package engine

import (
	"context"
	"fmt"

	lksdk "github.com/livekit/server-sdk-go/v2"
)

type LiveKitConnector struct{}

type liveKitSession struct {
	room *lksdk.Room
}

func NewLiveKitConnector() *LiveKitConnector {
	return &LiveKitConnector{}
}

func (c *LiveKitConnector) Connect(_ context.Context, params ConnectParams, callbacks Callbacks) (Session, error) {
	room, err := lksdk.ConnectToRoom(
		params.WSURL,
		lksdk.ConnectInfo{
			APIKey:              params.APIKey,
			APISecret:           params.APISecret,
			RoomName:            params.Room,
			ParticipantIdentity: params.Identity,
			ParticipantName:     params.Name,
		},
		&lksdk.RoomCallback{
			OnDisconnectedWithReason: func(reason lksdk.DisconnectionReason) {
				if callbacks.OnDisconnected != nil {
					callbacks.OnDisconnected(string(reason))
				}
			},
			ParticipantCallback: lksdk.ParticipantCallback{
				OnDataReceived: func(data []byte, recv lksdk.DataReceiveParams) {
					if callbacks.OnData != nil {
						callbacks.OnData(DataEvent{
							Payload:        data,
							Topic:          recv.Topic,
							SenderIdentity: recv.SenderIdentity,
						})
					}
				},
			},
		},
	)
	if err != nil {
		return nil, fmt.Errorf("connect to livekit room: %w", err)
	}

	return &liveKitSession{room: room}, nil
}

func (s *liveKitSession) PublishData(_ context.Context, req PublishDataRequest) error {
	opts := []lksdk.DataPublishOption{lksdk.WithDataPublishReliable(req.Reliable)}
	if req.Topic != "" {
		opts = append(opts, lksdk.WithDataPublishTopic(req.Topic))
	}
	if len(req.DestinationIdentities) > 0 {
		opts = append(opts, lksdk.WithDataPublishDestination(req.DestinationIdentities))
	}

	return s.room.LocalParticipant.PublishDataPacket(lksdk.UserData(req.Payload), opts...)
}

func (s *liveKitSession) Close() error {
	s.room.Disconnect()
	return nil
}
