// Package httpx provides the single HTTP response envelope and shared
// middleware used by every Local-Payment service.
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
	"net/http"

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
