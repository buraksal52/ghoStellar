package anchor

import "net/http"

// RegisterRoutes wires every route. The caller (cmd/anchorsvc/main.go)
// wraps this mux with authx.RequireBearer.
func RegisterRoutes(mux *http.ServeMux, h *Handler) {
	mux.HandleFunc("GET /anchors", h.List)
	mux.HandleFunc("GET /anchors/{id}/auth/challenge", h.Challenge)
	mux.HandleFunc("POST /anchors/{id}/auth/token", h.Token)
	mux.HandleFunc("POST /anchors/{id}/deposit", h.Deposit)
	mux.HandleFunc("POST /anchors/{id}/withdraw", h.Withdraw)
	mux.HandleFunc("GET /anchors/{id}/sep6/{path...}", h.Sep6)
	mux.HandleFunc("POST /anchors/{id}/sep6/{path...}", h.Sep6)
	mux.HandleFunc("GET /anchors/{id}/sep12/{path...}", h.Sep12)
	mux.HandleFunc("PUT /anchors/{id}/sep12/{path...}", h.Sep12)
	mux.HandleFunc("POST /anchors/{id}/sep12/{path...}", h.Sep12)
	mux.HandleFunc("GET /anchors/{id}/sep38/{path...}", h.Sep38)
	mux.HandleFunc("POST /anchors/{id}/sep38/{path...}", h.Sep38)
	mux.HandleFunc("POST /anchors/{id}/transactions/{txId}/report", h.ReportTransaction)
	mux.HandleFunc("GET /anchors/{id}/transactions", h.Transactions)
	mux.HandleFunc("POST /anchors/{id}/trustline-xdr", h.TrustlineXDR)
	mux.HandleFunc("POST /anchors/{id}/trustline-confirm", h.ConfirmTrustline)
}
