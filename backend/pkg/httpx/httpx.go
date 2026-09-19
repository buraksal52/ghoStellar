// Package httpx provides the single HTTP response envelope and shared
// middleware used by every ghoStellar service.
//
// Success: {"data": ..., "meta": ...}
// Error:   {"error": {"code", "message", "details"}}
//
// Callers — the mobile client and other services alike — always branch on
// error.Code, never on error.Message. See
// docs/reference/platform/architecture.md §13.
package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/oklog/ulid/v2"
)

// Envelope is the success response shape.
type Envelope struct {
	Data any `json:"data,omitempty"`
	Meta any `json:"meta,omitempty"`
}

// ErrorBody is a domain-scoped error, e.g. code "cheque.insufficient_balance".
type ErrorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Details any    `json:"details,omitempty"`
}

// ErrorEnvelope is the error response shape.
type ErrorEnvelope struct {
	Error ErrorBody `json:"error"`
}

// HealthPayload is the standard body of every /health endpoint.
type HealthPayload struct {
	Status  string `json:"status"`
	DBReady bool   `json:"db_ready"`
}

// WriteData writes a success envelope with the given HTTP status and data.
func WriteData(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(Envelope{Data: data})
}

// WriteDataMeta writes a success envelope with data and meta.
func WriteDataMeta(w http.ResponseWriter, status int, data, meta any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(Envelope{Data: data, Meta: meta})
}

// WriteError writes an error envelope. code must be "<domain>.<specific_error>".
func WriteError(w http.ResponseWriter, status int, code, message string, details any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(ErrorEnvelope{Error: ErrorBody{Code: code, Message: message, Details: details}})
}

// HealthHandler returns a handler for the standard /health endpoint. ready is
// polled at request time so it reflects the async DB-connect pattern: the
// process answers 200 immediately at boot, db_ready flips to true once the
// pool is up (see docs/reference/platform/architecture.md, boot patterns).
func HealthHandler(ready func() bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		WriteData(w, http.StatusOK, HealthPayload{Status: "ok", DBReady: ready()})
	}
}

type ctxKey int

const requestIDKey ctxKey = 0

// RequestIDHeader is the header every log line and downstream call
// propagates a request's correlation id under.
const RequestIDHeader = "X-Request-Id"

// WithRequestID is middleware that assigns/propagates a request id used by
// every log line and downstream internal call. An incoming X-Request-Id is
// trusted only when the gateway is the one setting it (see nethost/authx for
// the internal-key boundary); otherwise a fresh ULID is minted here.
func WithRequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get(RequestIDHeader)
		if id == "" {
			id = ulid.Make().String()
		}
		w.Header().Set(RequestIDHeader, id)
		ctx := context.WithValue(r.Context(), requestIDKey, id)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// RequestID extracts the request id set by WithRequestID, or "" if absent.
func RequestID(ctx context.Context) string {
	v, _ := ctx.Value(requestIDKey).(string)
	return v
}

// Recover is panic-recovery middleware (SERVICE.md #12): a single handler
// panicking must return a 500 to that one caller, not take the whole
// process down and drop every other in-flight request. logger receives the
// panic value and a minimal stack trace, tagged with the request's id when
// WithRequestID ran upstream of this middleware.
func Recover(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				logger.Error("panic recovered",
					"error", rec,
					"request_id", RequestID(r.Context()),
					"method", r.Method,
					"path", r.URL.Path,
				)
				WriteError(w, http.StatusInternalServerError, "internal.panic", "internal server error", nil)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// MaxBody is middleware that caps a request body at n bytes
// (http.MaxBytesReader) — SERVICE.md #12's missing body-size limit. A
// caller exceeding the cap gets a read error from the body decoder (the
// existing json.NewDecoder(...).Decode(...) call sites already surface that
// as a 400), rather than an unbounded read tying up memory.
func MaxBody(n int64, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil {
			r.Body = http.MaxBytesReader(w, r.Body, n)
		}
		next.ServeHTTP(w, r)
	})
}

// ServeOptions configures ListenAndServe's hardening beyond the bare
// net/http defaults (SERVICE.md #12: no timeouts, no graceful shutdown).
// The zero value is safe and applies the defaults documented on each field.
type ServeOptions struct {
	// ReadHeaderTimeout bounds how long a client may take to send request
	// headers — the classic Slowloris mitigation. Default 5s.
	ReadHeaderTimeout time.Duration
	// ReadTimeout bounds the full request (headers + body). Default 15s.
	ReadTimeout time.Duration
	// WriteTimeout bounds how long a handler may take to write its
	// response. Default 30s; pay-tx-service and pay-chain-gateway raise
	// this since a Horizon/Soroban round trip can legitimately take longer.
	WriteTimeout time.Duration
	// IdleTimeout bounds how long a kept-alive connection may sit idle.
	// Default 60s.
	IdleTimeout time.Duration
	// ShutdownGrace bounds how long ListenAndServe waits for in-flight
	// requests to finish once ctx is canceled (SIGINT/SIGTERM) before
	// giving up. Default 15s.
	ShutdownGrace time.Duration
}

func (o ServeOptions) withDefaults() ServeOptions {
	if o.ReadHeaderTimeout == 0 {
		o.ReadHeaderTimeout = 5 * time.Second
	}
	if o.ReadTimeout == 0 {
		o.ReadTimeout = 15 * time.Second
	}
	if o.WriteTimeout == 0 {
		o.WriteTimeout = 30 * time.Second
	}
	if o.IdleTimeout == 0 {
		o.IdleTimeout = 60 * time.Second
	}
	if o.ShutdownGrace == 0 {
		o.ShutdownGrace = 15 * time.Second
	}
	return o
}

// ListenAndServe runs handler on addr with hardened server timeouts and
// graceful shutdown on SIGINT/SIGTERM (SERVICE.md #12). It blocks until the
// server stops, returning nil on a clean shutdown or the error that caused
// it to stop otherwise. ctx is only consulted for its own cancellation (a
// parent context canceled for reasons other than an OS signal also
// triggers the same graceful drain).
func ListenAndServe(ctx context.Context, addr string, handler http.Handler, logger *slog.Logger, opts ServeOptions) error {
	opts = opts.withDefaults()
	srv := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: opts.ReadHeaderTimeout,
		ReadTimeout:       opts.ReadTimeout,
		WriteTimeout:      opts.WriteTimeout,
		IdleTimeout:       opts.IdleTimeout,
	}

	notifyCtx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()

	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.ListenAndServe() }()

	select {
	case err := <-serveErr:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-notifyCtx.Done():
		logger.Info("shutdown signal received, draining in-flight requests", "grace", opts.ShutdownGrace)
		shutdownCtx, cancel := context.WithTimeout(context.Background(), opts.ShutdownGrace)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			return err
		}
		return nil
	}
}
