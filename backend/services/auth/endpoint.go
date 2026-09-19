package auth

import "net/http"

// RegisterRoutes wires the public routes. /auth/me is expected to be
// wrapped with authx.RequireBearer by the caller (cmd/authsvc/main.go) —
// this file only defines routes, no middleware (architecture.md §13).
func RegisterRoutes(mux *http.ServeMux, h *Handler) {
	mux.HandleFunc("GET /auth/challenge", h.Challenge)
	mux.HandleFunc("POST /auth/token", h.Token)
	mux.HandleFunc("POST /auth/refresh", h.Refresh)
}

// RegisterProtectedRoutes wires routes that require a valid bearer token.
// mux here should already be behind authx.RequireBearer.
func RegisterProtectedRoutes(mux *http.ServeMux, h *Handler) {
	mux.HandleFunc("GET /auth/me", h.Me)
}
