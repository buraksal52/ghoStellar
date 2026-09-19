package chain

import "net/http"

// RegisterRoutes wires Handler onto mux under /internal — the caller
// (cmd/gatewaysvc/main.go) wraps this whole group with
// authx.RequireInternalKey.
func RegisterRoutes(mux *http.ServeMux, h *Handler) {
	mux.HandleFunc("GET /internal/accounts/{address}", h.GetAccount)
	mux.HandleFunc("GET /internal/accounts/{address}/trustline", h.GetTrustline)
	mux.HandleFunc("GET /internal/ledger", h.GetLedger)
	mux.HandleFunc("POST /internal/soroban/simulate", h.SimulateTransaction)
	mux.HandleFunc("POST /internal/submit/classic", h.SubmitClassic)
	mux.HandleFunc("POST /internal/submit/soroban", h.SubmitSoroban)
	mux.HandleFunc("POST /internal/fund", h.Fund)
}
