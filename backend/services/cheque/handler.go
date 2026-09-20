package cheque

import (
	"encoding/json"
	"errors"
	"io"
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

func callerAddress(r *http.Request) (string, bool) {
	claims, ok := authx.ClaimsFromContext(r.Context())
	if !ok {
		return "", false
	}
	return claims.StellarAccount, true
}

type createChequeRequest struct {
	Receiver string `json:"receiver"`
	Amount   string `json:"amount"`
	// RequestID is the receiver's single-use payment-request id (optional).
	RequestID string `json:"requestId"`
}

func (h *Handler) CreateCheque(w http.ResponseWriter, r *http.Request) {
	sender, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	var req createChequeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "invalid JSON body", nil)
		return
	}
	result, err := h.svc.CreateCheque(r.Context(), sender, req.Receiver, req.Amount, req.RequestID)
	if err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusCreated, result)
}

type preauthRequest struct {
	SignedEntryXDR string `json:"signedEntryXdr"`
}

func (h *Handler) StorePreauth(w http.ResponseWriter, r *http.Request) {
	caller, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	id := r.PathValue("id")
	var req preauthRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.SignedEntryXDR == "" {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "signedEntryXdr is required", nil)
		return
	}
	if err := h.svc.StorePreauth(r.Context(), id, caller, req.SignedEntryXDR); err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"stored": true})
}

func (h *Handler) ClaimXDR(w http.ResponseWriter, r *http.Request) {
	receiver, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	id := r.PathValue("id")
	xdrStr, err := h.svc.ClaimXDR(r.Context(), id, receiver)
	if err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]string{"claimXdr": xdrStr})
}

func (h *Handler) ForceCollectXDR(w http.ResponseWriter, r *http.Request) {
	receiver, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	id := r.PathValue("id")
	xdrStr, err := h.svc.ForceCollectXDR(r.Context(), id, receiver)
	if err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]string{"forceCollectXdr": xdrStr})
}

type confirmRequest struct {
	TxHash string `json:"txHash"`
}

func (h *Handler) ConfirmLock(w http.ResponseWriter, r *http.Request) {
	caller, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	id := r.PathValue("id")
	var req confirmRequest
	if err := decodeConfirmBody(r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "invalid JSON body", nil)
		return
	}
	if err := h.svc.ConfirmLock(r.Context(), id, caller, req.TxHash); err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"confirmed": true})
}

func (h *Handler) ConfirmClaim(w http.ResponseWriter, r *http.Request) {
	caller, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	id := r.PathValue("id")
	var req confirmRequest
	if err := decodeConfirmBody(r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "invalid JSON body", nil)
		return
	}
	if err := h.svc.ConfirmClaim(r.Context(), id, caller, req.TxHash); err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"confirmed": true})
}

func (h *Handler) AcknowledgeReceipt(w http.ResponseWriter, r *http.Request) {
	caller, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	id := r.PathValue("id")
	if err := h.svc.AcknowledgeReceipt(r.Context(), id, caller); err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"acknowledged": true})
}

type confirmForceCollectRequest struct {
	TxHash string `json:"txHash"`
	// Collected is a pointer so a missing/malformed field is distinguishable
	// from an explicit `false` — this is the most consequential state
	// transition in the product (a nil default silently masquerading as
	// `false` would mark a real collection as KARSILIKSIZ), so it must be
	// rejected rather than defaulted.
	Collected *bool `json:"collected"`
}

func (h *Handler) ConfirmForceCollect(w http.ResponseWriter, r *http.Request) {
	caller, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	id := r.PathValue("id")
	var req confirmForceCollectRequest
	if err := decodeConfirmBody(r, &req); err != nil || req.Collected == nil {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "collected is required", nil)
		return
	}
	if err := h.svc.ConfirmForceCollect(r.Context(), id, caller, req.TxHash, *req.Collected); err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"confirmed": true})
}

// decodeConfirmBody decodes a request body that MUST be present and
// well-formed JSON — unlike the {} bodies confirm-lock/confirm-claim accept
// with an empty txHash, a malformed body here is an error, not a silent
// zero-value default (Fix 2: the three confirm-* handlers used to swallow
// this error with `_ = json.NewDecoder(...).Decode(...)`).
func decodeConfirmBody(r *http.Request, v any) error {
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(v); err != nil {
		if err == io.EOF {
			// An empty body is the documented shape for confirm-lock/
			// confirm-claim (scripts/e2e.sh sends '{}', which decodes the
			// same as EOF into a zero-value struct) — leave v untouched.
			return nil
		}
		return err
	}
	return nil
}

func (h *Handler) Sync(w http.ResponseWriter, r *http.Request) {
	address, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	view, err := h.svc.Sync(r.Context(), address)
	if err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, view)
}

type poolAmountRequest struct {
	Amount string `json:"amount"`
}

func (h *Handler) PoolDepositXDR(w http.ResponseWriter, r *http.Request) {
	owner, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	var req poolAmountRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "invalid JSON body", nil)
		return
	}
	xdrStr, err := h.svc.PoolDepositXDR(r.Context(), owner, req.Amount)
	if err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]string{"depositXdr": xdrStr})
}

func (h *Handler) PoolWithdrawXDR(w http.ResponseWriter, r *http.Request) {
	owner, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	var req poolAmountRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "invalid JSON body", nil)
		return
	}
	xdrStr, err := h.svc.PoolWithdrawXDR(r.Context(), owner, req.Amount)
	if err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]string{"withdrawXdr": xdrStr})
}

func (h *Handler) ConfirmPoolDeposit(w http.ResponseWriter, r *http.Request) {
	owner, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	var req struct {
		Amount    string `json:"amount"`
		LedgerSeq int64  `json:"ledgerSeq"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "invalid JSON body", nil)
		return
	}
	if err := h.svc.ConfirmPoolDeposit(r.Context(), owner, req.Amount, req.LedgerSeq); err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"confirmed": true})
}

func (h *Handler) ConfirmPoolWithdraw(w http.ResponseWriter, r *http.Request) {
	owner, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	var req poolAmountRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "invalid JSON body", nil)
		return
	}
	if err := h.svc.ConfirmPoolWithdraw(r.Context(), owner, req.Amount); err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"confirmed": true})
}

func writeChequeError(w http.ResponseWriter, err error) {
	code, status := ErrBadRequest, http.StatusBadRequest
	switch {
	case errors.Is(err, ErrDBNotReadyErr):
		code, status = ErrDBNotReady, http.StatusServiceUnavailable
	case errors.Is(err, errInsufficientBalance):
		code, status = ErrInsufficientBalance, http.StatusUnprocessableEntity
	case errors.Is(err, errAlreadyActive):
		code, status = ErrAlreadyActive, http.StatusConflict
	case errors.Is(err, errInvalidReceiver):
		code, status = ErrInvalidReceiver, http.StatusBadRequest
	case errors.Is(err, errReceiverNoTrustline):
		code, status = ErrReceiverNoTrustline, http.StatusUnprocessableEntity
	case errors.Is(err, errSelfTransfer):
		code, status = ErrSelfTransfer, http.StatusBadRequest
	case errors.Is(err, errRequestUsed):
		code, status = ErrRequestUsed, http.StatusConflict
	case errors.Is(err, errInvalidRequestID):
		code, status = ErrInvalidRequestID, http.StatusBadRequest
	case errors.Is(err, errInvalidAmount):
		code, status = ErrInvalidAmount, http.StatusBadRequest
	case errors.Is(err, errExpired):
		code, status = ErrExpired, http.StatusConflict
	case errors.Is(err, errTerminalState):
		code, status = ErrTerminalState, http.StatusConflict
	case errors.Is(err, errNotFound):
		code, status = ErrNotFound, http.StatusNotFound
	case errors.Is(err, errPoolWithdrawLocked):
		code, status = ErrPoolWithdrawLocked, http.StatusConflict
	case errors.Is(err, errChainUnavailable):
		code, status = ErrChainUnavailable, http.StatusBadGateway
	case errors.Is(err, errAccountNotFunded):
		code, status = ErrAccountNotFunded, http.StatusUnprocessableEntity
	case errors.Is(err, errSimulationFailed):
		code, status = ErrSimulationFailed, http.StatusUnprocessableEntity
	}
	httpx.WriteError(w, status, code, err.Error(), nil)
}
