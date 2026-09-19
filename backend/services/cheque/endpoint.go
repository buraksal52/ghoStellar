package cheque

import "net/http"

// RegisterRoutes wires every route. The caller (cmd/chequesvc/main.go)
// wraps this whole mux with authx.RequireBearer — every route needs an
// authenticated caller (architecture.md §13: route definitions only here).
func RegisterRoutes(mux *http.ServeMux, h *Handler) {
	mux.HandleFunc("POST /cheques", h.CreateCheque)
	mux.HandleFunc("POST /cheques/{id}/preauth", h.StorePreauth)
	mux.HandleFunc("POST /cheques/{id}/claim-xdr", h.ClaimXDR)
	mux.HandleFunc("POST /cheques/{id}/force-collect-xdr", h.ForceCollectXDR)
	mux.HandleFunc("POST /cheques/{id}/confirm-lock", h.ConfirmLock)
	mux.HandleFunc("POST /cheques/{id}/confirm-claim", h.ConfirmClaim)
	mux.HandleFunc("POST /cheques/{id}/confirm-force-collect", h.ConfirmForceCollect)
	mux.HandleFunc("POST /cheques/{id}/ack", h.AcknowledgeReceipt)

	mux.HandleFunc("GET /sync", h.Sync)

	mux.HandleFunc("POST /pool/deposit-xdr", h.PoolDepositXDR)
	mux.HandleFunc("POST /pool/withdraw-xdr", h.PoolWithdrawXDR)
	mux.HandleFunc("POST /pool/confirm-deposit", h.ConfirmPoolDeposit)
	mux.HandleFunc("POST /pool/confirm-withdraw", h.ConfirmPoolWithdraw)
}
