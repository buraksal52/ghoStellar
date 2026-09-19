package anchor

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

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

func anchorTokenFromHeader(r *http.Request) string {
	return r.Header.Get("X-Anchor-Token")
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	info, err := h.svc.Info(r.Context(), h.svc.cfg.AnchorID)
	if err != nil {
		writeAnchorError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, []Info{info})
}

func (h *Handler) Challenge(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	account, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	xdrStr, err := h.svc.Challenge(r.Context(), id, account)
	if err != nil {
		writeAnchorError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]string{"transaction": xdrStr})
}

type tokenRequest struct {
	Transaction string `json:"transaction"`
}

func (h *Handler) Token(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req tokenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Transaction == "" {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "transaction is required", nil)
		return
	}
	token, err := h.svc.Token(r.Context(), id, req.Transaction)
	if err != nil {
		writeAnchorError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]string{"token": token})
}

func (h *Handler) Deposit(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	address, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	txID, url, err := h.svc.StartDeposit(r.Context(), id, anchorTokenFromHeader(r), address)
	if err != nil {
		writeAnchorError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]string{"id": txID, "url": url})
}

func (h *Handler) Withdraw(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	address, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	txID, url, err := h.svc.StartWithdraw(r.Context(), id, anchorTokenFromHeader(r), address)
	if err != nil {
		writeAnchorError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]string{"id": txID, "url": url})
}

type reportRequest struct {
	Kind          string `json:"kind"`
	State         string `json:"state"`
	Amount        string `json:"amount"`
	Decimals      uint8  `json:"decimals"`
	StellarTxHash string `json:"stellarTxHash"`
}

// ReportTransaction is the self-report endpoint documented in
// docs/reference/platform/anchor-entegrasyonu.md: the client is the only
// party holding the anchor's JWT, so it is the one that observed this
// state from the anchor directly.
func (h *Handler) ReportTransaction(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	txID := r.PathValue("txId")
	address, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	var req reportRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "invalid JSON body", nil)
		return
	}
	err := h.svc.ReportTransaction(r.Context(), id, address, Transaction{
		ID: txID, Kind: req.Kind, State: req.State, AmountRaw: req.Amount, Decimals: req.Decimals, StellarTxHash: req.StellarTxHash,
	})
	if err != nil {
		writeAnchorError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"recorded": true})
}

func (h *Handler) Transactions(w http.ResponseWriter, r *http.Request) {
	address, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	list, err := h.svc.ListTransactions(r.Context(), address)
	if err != nil {
		writeAnchorError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, list)
}

func (h *Handler) TrustlineXDR(w http.ResponseWriter, r *http.Request) {
	address, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	xdrStr, err := h.svc.TrustlineXDR(r.Context(), address)
	if err != nil {
		writeAnchorError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]string{"trustlineXdr": xdrStr})
}

type confirmTrustlineRequest struct {
	LedgerSeq int64 `json:"ledgerSeq"`
}

func (h *Handler) ConfirmTrustline(w http.ResponseWriter, r *http.Request) {
	address, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	var req confirmTrustlineRequest
	_ = json.NewDecoder(r.Body).Decode(&req)
	if err := h.svc.ConfirmTrustline(r.Context(), address, req.LedgerSeq); err != nil {
		writeAnchorError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"confirmed": true})
}

func writeAnchorError(w http.ResponseWriter, err error) {
	code, status := ErrUpstreamFailed, http.StatusBadGateway
	switch {
	case errors.Is(err, ErrDBNotReadyErr):
		code, status = ErrDBNotReady, http.StatusServiceUnavailable
	case errors.Is(err, errNotAllowed):
		code, status = ErrNotAllowed, http.StatusNotFound
	case errors.Is(err, errAuthRequired):
		code, status = ErrAuthRequired, http.StatusUnauthorized
	case errors.Is(err, errChainUnavailable):
		code, status = ErrChainUnavailable, http.StatusBadGateway
	case strings.Contains(err.Error(), ErrTomlUnavailable):
		code, status = ErrTomlUnavailable, http.StatusBadGateway
	}
	httpx.WriteError(w, status, code, err.Error(), nil)
}
