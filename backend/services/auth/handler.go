package auth

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/httpx"
	"github.com/local-payment/backend/pkg/stellarx"
)

// Handler binds HTTP to Service — decode/validate/respond only
// (docs/reference/platform/architecture.md §13). /auth/me's bearer
// verification happens in middleware (authx.RequireBearer, wired in
// cmd/authsvc/main.go); Me only reads the Claims that middleware injected.
type Handler struct {
	svc *Service
}

func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

func (h *Handler) Challenge(w http.ResponseWriter, r *http.Request) {
	account := r.URL.Query().Get("account")
	if !stellarx.IsValidAccountAddress(account) {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "account query param must be a valid G... address", nil)
		return
	}
	xdrStr, err := h.svc.Challenge(account)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, ErrBadRequest, err.Error(), nil)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]string{"transaction": xdrStr, "networkPassphrase": h.svc.cfg.NetworkPassphrase})
}

type tokenRequest struct {
	Transaction string `json:"transaction"`
}

func (h *Handler) Token(w http.ResponseWriter, r *http.Request) {
	var req tokenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Transaction == "" {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "transaction (signed challenge XDR) is required", nil)
		return
	}
	pair, _, err := h.svc.VerifyAndMint(r.Context(), req.Transaction)
	if err != nil {
		digest := sha256.Sum256([]byte(req.Transaction))
		category := "other"
		if errors.Is(err, errInvalidChallenge) {
			category = "challenge_invalid"
		} else if errors.Is(err, errInvalidSignature) {
			category = "client_signature_invalid"
		}
		slog.Warn("temporary SEP-10 rejection diagnostic",
			"category", category,
			"transaction_sha256_prefix", fmt.Sprintf("%x", digest[:6]),
			"transaction_bytes", len(req.Transaction),
		)
		httpx.WriteError(w, http.StatusUnauthorized, ErrInvalidSignature, "challenge verification failed", nil)
		return
	}
	httpx.WriteData(w, http.StatusOK, pair)
}

type refreshRequest struct {
	RefreshToken string `json:"refreshToken"`
}

func (h *Handler) Refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RefreshToken == "" {
		httpx.WriteError(w, http.StatusBadRequest, ErrBadRequest, "refreshToken is required", nil)
		return
	}
	pair, err := h.svc.Refresh(req.RefreshToken)
	if err != nil {
		httpx.WriteError(w, http.StatusUnauthorized, ErrInvalidToken, "refresh token invalid or expired", nil)
		return
	}
	httpx.WriteData(w, http.StatusOK, pair)
}

func (h *Handler) Me(w http.ResponseWriter, r *http.Request) {
	claims, ok := authx.ClaimsFromContext(r.Context())
	if !ok {
		httpx.WriteError(w, http.StatusUnauthorized, ErrInvalidToken, "missing bearer claims", nil)
		return
	}
	user, err := h.svc.GetProfile(r.Context(), claims.StellarAccount)
	if err != nil {
		httpx.WriteError(w, http.StatusNotFound, "auth.user_not_found", "no profile for this account yet", nil)
		return
	}
	httpx.WriteData(w, http.StatusOK, user)
}
