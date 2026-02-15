package adapter

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/midwest-dads/livekit-realtime-sdk/go/internal/config"
	"github.com/midwest-dads/livekit-realtime-sdk/go/internal/session"
)

type Server struct {
	cfg     *config.Config
	manager *session.Manager
	logger  *slog.Logger
	httpSrv *http.Server
	handler http.Handler
}

func New(cfg *config.Config, manager *session.Manager, logger *slog.Logger) *Server {
	mux := http.NewServeMux()
	s := &Server{cfg: cfg, manager: manager, logger: logger}

	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.Handle("POST /v1/sessions", s.withAuth(http.HandlerFunc(s.handleCreateSession)))
	mux.Handle("GET /v1/sessions/{id}/events", s.withAuth(http.HandlerFunc(s.handleSessionEvents)))
	mux.Handle("POST /v1/sessions/{id}/data", s.withAuth(http.HandlerFunc(s.handleSessionData)))
	mux.Handle("DELETE /v1/sessions/{id}", s.withAuth(http.HandlerFunc(s.handleCloseSession)))

	s.handler = withRequestLogging(logger, mux)
	s.httpSrv = &http.Server{
		Addr:              cfg.AdapterAddr,
		Handler:           s.handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	return s
}

func (s *Server) Handler() http.Handler {
	return s.handler
}

func (s *Server) Start() error {
	s.logger.Info("adapter listening", "addr", s.cfg.AdapterAddr)
	if err := s.httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("listen: %w", err)
	}
	return nil
}

func (s *Server) Shutdown(ctx context.Context) error {
	return s.httpSrv.Shutdown(ctx)
}

func (s *Server) withAuth(next http.Handler) http.Handler {
	if s.cfg.SharedSecret == "" {
		return next
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		const prefix = "Bearer "
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, prefix) {
			writeError(w, http.StatusUnauthorized, "missing bearer token")
			return
		}

		token := strings.TrimPrefix(auth, prefix)
		if token != s.cfg.SharedSecret {
			writeError(w, http.StatusForbidden, "invalid token")
			return
		}

		next.ServeHTTP(w, r)
	})
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

type createSessionRequest struct {
	Room     string `json:"room"`
	Identity string `json:"identity"`
	Name     string `json:"name,omitempty"`
}

func (s *Server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	var req createSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.Room == "" || req.Identity == "" {
		writeError(w, http.StatusBadRequest, "room and identity are required")
		return
	}

	id, err := s.manager.Create(r.Context(), session.CreateInput{
		WSURL:     s.cfg.LiveKitWSURL,
		APIKey:    s.cfg.LiveKitAPIKey,
		APISecret: s.cfg.LiveKitAPISecret,
		Room:      req.Room,
		Identity:  req.Identity,
		Name:      req.Name,
	})
	if err != nil {
		s.logger.Error("create session failed", "error", err)
		writeError(w, http.StatusBadGateway, "failed to connect to LiveKit")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]string{"session_id": id})
}

type publishDataRequest struct {
	PayloadBase64         string   `json:"payload_base64"`
	Topic                 string   `json:"topic,omitempty"`
	Reliable              bool     `json:"reliable"`
	DestinationIdentities []string `json:"destination_identities,omitempty"`
}

func (s *Server) handleSessionData(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}

	var req publishDataRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	payload, err := base64.StdEncoding.DecodeString(req.PayloadBase64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "payload_base64 must be valid base64")
		return
	}

	err = s.manager.PublishData(r.Context(), id, session.PublishInput{
		Payload:               payload,
		Topic:                 req.Topic,
		Reliable:              req.Reliable,
		DestinationIdentities: req.DestinationIdentities,
	})
	if err != nil {
		handleSessionError(w, err)
		return
	}

	writeJSON(w, http.StatusAccepted, map[string]string{"status": "queued"})
}

func (s *Server) handleSessionEvents(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}

	ch, unsubscribe, err := s.manager.Subscribe(id)
	if err != nil {
		handleSessionError(w, err)
		return
	}
	defer unsubscribe()

	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming not supported")
		return
	}
	flusher.Flush()

	enc := json.NewEncoder(w)
	for {
		select {
		case <-r.Context().Done():
			return
		case evt, open := <-ch:
			if !open {
				return
			}
			if err := enc.Encode(evt); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

func (s *Server) handleCloseSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}

	if err := s.manager.Close(id); err != nil {
		handleSessionError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "closed"})
}

func handleSessionError(w http.ResponseWriter, err error) {
	if errors.Is(err, session.ErrSessionNotFound) {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}
	writeError(w, http.StatusBadGateway, "adapter operation failed")
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func withRequestLogging(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		logger.Debug("request", "method", r.Method, "path", r.URL.Path, "duration", time.Since(start))
	})
}
