package config

import (
	"errors"
	"fmt"
	"os"
)

type Config struct {
	AdapterAddr      string
	LiveKitWSURL     string
	LiveKitAPIKey    string
	LiveKitAPISecret string
	SharedSecret     string
}

func Load() (*Config, error) {
	cfg := &Config{
		AdapterAddr:      envOrDefault("ADAPTER_ADDR", "127.0.0.1:8787"),
		LiveKitWSURL:     firstNonEmpty(os.Getenv("LIVEKIT_WS_URL"), os.Getenv("LIVEKIT_URL")),
		LiveKitAPIKey:    os.Getenv("LIVEKIT_API_KEY"),
		LiveKitAPISecret: os.Getenv("LIVEKIT_API_SECRET"),
		SharedSecret:     os.Getenv("SHARED_SECRET"),
	}

	if cfg.LiveKitWSURL == "" {
		return nil, errors.New("missing LIVEKIT_WS_URL (or LIVEKIT_URL)")
	}
	if cfg.LiveKitAPIKey == "" {
		return nil, errors.New("missing LIVEKIT_API_KEY")
	}
	if cfg.LiveKitAPISecret == "" {
		return nil, errors.New("missing LIVEKIT_API_SECRET")
	}
	if cfg.AdapterAddr == "" {
		return nil, fmt.Errorf("invalid ADAPTER_ADDR")
	}

	return cfg, nil
}

func envOrDefault(key string, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
