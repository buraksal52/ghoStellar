package cheque

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
	result, err := h.svc.CreateCheque(r.Context(), sender, req.Receiver, req.Amount)
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
	_ = json.NewDecoder(r.Body).Decode(&req)
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
	_ = json.NewDecoder(r.Body).Decode(&req)
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
	TxHash    string `json:"txHash"`
	Collected bool   `json:"collected"`
}

func (h *Handler) ConfirmForceCollect(w http.ResponseWriter, r *http.Request) {
	caller, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	id := r.PathValue("id")
	var req confirmForceCollectRequest
	_ = json.NewDecoder(r.Body).Decode(&req)
	if err := h.svc.ConfirmForceCollect(r.Context(), id, caller, req.TxHash, req.Collected); err != nil {
		writeChequeError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"confirmed": true})
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
	}
	httpx.WriteError(w, status, code, err.Error(), nil)
}
