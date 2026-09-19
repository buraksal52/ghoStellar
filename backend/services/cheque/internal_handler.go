package cheque

import (
	"encoding/json"
	"net/http"

	"github.com/local-payment/backend/pkg/httpx"
)

// InternalHandler exposes the sweep operations pay-scheduler-service needs
// — guarded by authx.RequireInternalKey in cmd/chequesvc/main.go, never
// reachable from outside the cluster. Kept separate from Handler because
// these routes answer to no single user's bearer token (architecture.md
// §13's file template still applies: decode/validate/respond only).
type InternalHandler struct {
	svc *Service
}

func NewInternalHandler(svc *Service) *InternalHandler {
	return &InternalHandler{svc: svc}
}

func (h *InternalHandler) ExpiredFunded(w http.ResponseWriter, r *http.Request) {
	list, err := h.svc.ExpiredFundedCheques(r.Context())
	if err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, list)
}

type markRefundedRequest struct {
	TxHash string `json:"txHash"`
}

func (h *InternalHandler) MarkRefunded(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req markRefundedRequest
	_ = json.NewDecoder(r.Body).Decode(&req)
	if err := h.svc.MarkRefunded(r.Context(), id, req.TxHash); err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"marked": true})
}

// RegisterInternalRoutes wires the sweep routes onto mux.
func RegisterInternalRoutes(mux *http.ServeMux, h *InternalHandler) {
	mux.HandleFunc("GET /internal/cheques/expired-funded", h.ExpiredFunded)
	mux.HandleFunc("POST /internal/cheques/{id}/mark-refunded", h.MarkRefunded)
}
