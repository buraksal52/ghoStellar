// Package obs provides the structured JSON logger shared by every
// ghoStellar service. OTel/Prometheus are explicitly out of scope for
// this MVP (see the plan's "Kesilen prod fazlalıkları" section) — this
// package stays a thin slog wrapper on purpose.
package obs

import (
	"log/slog"
	"os"
)

// NewLogger returns the process-wide structured JSON logger for a service.
// Every log line should carry request_id and, where applicable, user_id and
// cheque_id, added via slog.With — never string concatenation.
func NewLogger(service string) *slog.Logger {
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})
	return slog.New(h).With("service", service)
}
