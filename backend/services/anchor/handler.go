package anchor

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/httpx"
)

type Handler struct {
	svc *Service
	log *slog.Logger
}

func (h *Handler) sepProxy(w http.ResponseWriter, r *http.Request, sep string) {
	id := r.PathValue("id")
	if _, ok := callerAddress(r); !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	var body []byte
	contentType := r.Header.Get("Content-Type")
	// A real SEP-12 KYC upload (identity photos, etc.) can be
	// multipart/form-data — that body is not, and never will be, valid
	// JSON, so it is exempted from the json.Valid check below and handed
	// through byte-for-byte with its original Content-Type preserved
	// (SERVICE.md #7). Every other SEP call keeps requiring JSON.
	isMultipart := strings.HasPrefix(contentType, "multipart/")
	bodyLimit := int64(1 << 20)
	if isMultipart {
		bodyLimit = 8 << 20 // KYC file uploads need more headroom than a JSON body
	}
	if r.Body != nil && r.Method != http.MethodGet {
		var err error
		body, err = io.ReadAll(io.LimitReader(r.Body, bodyLimit))
		if err != nil {
			httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "invalid request body", nil)
			return
		}
		if !isMultipart && len(body) != 0 && !json.Valid(body) {
			httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "body must be valid JSON", nil)
			return
		}
	}
	var result json.RawMessage
	var err error
	path, query, token := r.PathValue("path"), r.URL.RawQuery, anchorTokenFromHeader(r)
	if sep == "sep6" && (path == "deposit" || path == "withdraw") && r.Method == http.MethodGet {
		account, _ := callerAddress(r)
		values, err := url.ParseQuery(query)
		if err != nil {
			httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "invalid query string", nil)
			return
		}
		if requested := values.Get("account"); requested != "" && requested != account {
			httpx.WriteError(w, http.StatusForbidden, ErrNotAllowed, "deposit account must match the authenticated Stellar account", nil)
			return
		}
		if path == "deposit" {
			values.Set("account", account)
		}
		query = values.Encode()
	}
	if !(sep == "sep6" && path == "info") && strings.TrimSpace(token) == "" {
		httpx.WriteError(w, http.StatusUnauthorized, ErrAuthRequired, "X-Anchor-Token is required", nil)
		return
	}
	switch sep {
	case "sep6":
		result, err = h.svc.ProxySep6(r.Context(), id, r.Method, path, query, token, contentType, body)
	case "sep12":
		result, err = h.svc.ProxySep12(r.Context(), id, r.Method, path, query, token, contentType, body)
	case "sep38":
		result, err = h.svc.ProxySep38(r.Context(), id, r.Method, path, query, token, contentType, body)
	}
	if err != nil {
		writeAnchorError(w, err)
		return
	}
	if sep == "sep6" && r.Method == http.MethodGet && (path == "deposit" || path == "withdraw") {
		var started struct {
			ID            string `json:"id"`
			TransactionID string `json:"transaction_id"`
		}
		if json.Unmarshal(result, &started) == nil {
			txID := started.ID
			if txID == "" {
				txID = started.TransactionID
			}
			if txID != "" {
				kind := path
				address, _ := callerAddress(r)
				// Best-effort: the anchor has ALREADY accepted this
				// deposit/withdraw at this point (result holds its real
				// {id,how,more_info_url,...} response). A local bookkeeping
				// failure here must never make a genuinely successful
				// anchor call look like a failure to the user — that would
				// hide their deposit instructions / withdraw destination
				// even though the anchor-side transaction really exists.
				// Log and continue; the user's own report call or a future
				// reconcile pass can repair the local row.
				if err := h.svc.RecordSep6Transaction(r.Context(), id, address, Transaction{ID: txID, Kind: kind, State: "pending_user_transfer_start"}); err != nil {
					h.log.Warn("failed to record sep6 transaction locally; anchor call itself succeeded",
						"anchor_id", id, "tx_id", txID, "kind", kind, "error", err)
				}
			}
		}
	}
	httpx.WriteData(w, http.StatusOK, result)
}

func (h *Handler) Sep6(w http.ResponseWriter, r *http.Request)  { h.sepProxy(w, r, "sep6") }
func (h *Handler) Sep12(w http.ResponseWriter, r *http.Request) { h.sepProxy(w, r, "sep12") }
func (h *Handler) Sep38(w http.ResponseWriter, r *http.Request) { h.sepProxy(w, r, "sep38") }

func NewHandler(svc *Service, log *slog.Logger) *Handler {
	return &Handler{svc: svc, log: log}
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
	xdrStr, networkPassphrase, err := h.svc.Challenge(r.Context(), id, account)
	if err != nil {
		writeAnchorError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]string{
		"transaction":       xdrStr,
		"networkPassphrase": networkPassphrase,
	})
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

type withdrawPaymentRequest struct {
	Destination string `json:"destination"`
	MemoType    string `json:"memoType"`
	Memo        string `json:"memo"`
	Amount      string `json:"amount"`
}

func (h *Handler) WithdrawPaymentXDR(w http.ResponseWriter, r *http.Request) {
	address, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	if err := h.svc.checkID(r.PathValue("id")); err != nil {
		writeAnchorError(w, err)
		return
	}
	var req withdrawPaymentRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "destination and amount are required", nil)
		return
	}
	xdrStr, err := h.svc.WithdrawPaymentXDR(r.Context(), address, req.Destination, req.MemoType, req.Memo, req.Amount)
	if err != nil {
		writeAnchorError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]string{"paymentXdr": xdrStr})
}

// ConfirmTrustline takes no body: the service verifies the trustline against
// the chain itself.
func (h *Handler) ConfirmTrustline(w http.ResponseWriter, r *http.Request) {
	address, ok := callerAddress(r)
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
		return
	}
	if err := h.svc.ConfirmTrustline(r.Context(), address); err != nil {
		writeAnchorError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"confirmed": true})
}

func isAnchorAuthError(err error) bool {
	var ae *anchorAuthError
	return errors.As(err, &ae)
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
	case errors.Is(err, ErrNotFoundInRepo):
		code, status = ErrNotAllowed, http.StatusForbidden
	case errors.Is(err, errChainUnavailable):
		code, status = ErrChainUnavailable, http.StatusBadGateway
	case errors.Is(err, errTrustlineMissing):
		code, status = ErrTrustlineMissing, http.StatusUnprocessableEntity
	case errors.Is(err, errBadRequest):
		code, status = ErrBadRequest, http.StatusBadRequest
	case errors.Is(err, errAccountNotFunded):
		code, status = ErrAccountNotFunded, http.StatusUnprocessableEntity
	case isAnchorAuthError(err):
		// 403, not 401: the app's ApiClient treats any 401 as ITS OWN
		// session expiring and would wipe the user's tokens.
		code, status = ErrTokenRejected, http.StatusForbidden
	case strings.Contains(err.Error(), ErrTomlUnavailable):
		code, status = ErrTomlUnavailable, http.StatusBadGateway
	}
	httpx.WriteError(w, status, code, err.Error(), nil)
}
