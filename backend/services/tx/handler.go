package tx

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/httpx"
)

type Handler struct {
	svc *Service
}

func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

type submitRequest struct {
	IdempotencyKey string `json:"idempotencyKey"`
	Purpose        string `json:"purpose"`
	Kind           string `json:"kind"` // "classic" | "soroban"
	XDR            string `json:"xdr"`
}

func (h *Handler) Submit(w http.ResponseWriter, r *http.Request) {
	claims, ok := authx.ClaimsFromContext(r.Context())
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	var req submitRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "invalid JSON body", nil)
		return
	}
	if req.IdempotencyKey == "" || req.XDR == "" || req.Purpose == "" {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "idempotencyKey, purpose and xdr are required", nil)
		return
	}

	kind := KindClassic
	if req.Kind == string(KindSoroban) {
		kind = KindSoroban
	}

	resp, err := h.svc.Submit(r.Context(), SubmitRequest{
		IdempotencyKey: req.IdempotencyKey,
		StellarAddress: claims.StellarAccount,
		Purpose:        req.Purpose,
		Kind:           kind,
		SignedXDR:      req.XDR,
	})
	if err != nil {
		writeTxError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, resp)
}

func (h *Handler) GetSubmission(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	sub, err := h.svc.GetSubmission(r.Context(), key)
	if err != nil {
		writeTxError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, sub)
}

func writeTxError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrDBNotReadyErr):
		httpx.WriteError(w, http.StatusServiceUnavailable, ErrDBNotReady, "database not ready yet", nil)
	case errors.Is(err, errKeyInFlight):
		httpx.WriteError(w, http.StatusConflict, ErrDuplicateIdempotencyKey, "this idempotency key is already being processed", nil)
	case errors.Is(err, errNotFound):
		httpx.WriteError(w, http.StatusNotFound, ErrNotFound, "no submission with that idempotency key", nil)
	default:
		httpx.WriteError(w, http.StatusBadGateway, ErrSubmitFailed, err.Error(), nil)
	}
}
