package tx

import "net/http"

// RegisterRoutes wires tx-service's routes onto mux, which the caller
// (cmd/txsvc/main.go) wraps with authx.RequireBearer — every route here
// needs an authenticated caller.
func RegisterRoutes(mux *http.ServeMux, h *Handler) {
	mux.HandleFunc("POST /tx/submit", h.Submit)
	mux.HandleFunc("GET /tx/{key}", h.GetSubmission)
}
