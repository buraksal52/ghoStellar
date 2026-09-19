package chain

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/local-payment/backend/pkg/httpx"
)

// Handler exposes Service over HTTP for other services to call via
// httpadapter, guarded upstream by authx.RequireInternalKey. decode/
// validate/respond only — no business logic (architecture.md §13).
type Handler struct {
	svc *Service
}

func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

func (h *Handler) GetAccount(w http.ResponseWriter, r *http.Request) {
	address := r.PathValue("address")
	info, err := h.svc.GetAccount(r.Context(), address)
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "chain.rpc_unavailable", err.Error(), nil)
		return
	}
	httpx.WriteData(w, http.StatusOK, info)
}

func (h *Handler) GetTrustline(w http.ResponseWriter, r *http.Request) {
	address := r.PathValue("address")
	q := r.URL.Query()
	code := q.Get("code")
	issuer := q.Get("issuer")
	if code == "" {
		httpx.WriteError(w, http.StatusBadRequest, "chain.missing_asset_code", "code query param required", nil)
		return
	}
	info, err := h.svc.GetTrustline(r.Context(), address, code, issuer)
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "chain.rpc_unavailable", err.Error(), nil)
		return
	}
	httpx.WriteData(w, http.StatusOK, info)
}

func (h *Handler) GetLedger(w http.ResponseWriter, r *http.Request) {
	info, err := h.svc.GetLedger(r.Context())
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "chain.rpc_unavailable", err.Error(), nil)
		return
	}
	httpx.WriteData(w, http.StatusOK, info)
}

type simulateRequest struct {
	XDR string `json:"xdr"`
}

func (h *Handler) SimulateTransaction(w http.ResponseWriter, r *http.Request) {
	var req simulateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "chain.bad_request", "invalid JSON body", nil)
		return
	}
	result, err := h.svc.SimulateTransaction(r.Context(), req.XDR)
	if err != nil {
		writeChainError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, result)
}

type submitRequest struct {
	XDR string `json:"xdr"`
}

func (h *Handler) SubmitClassic(w http.ResponseWriter, r *http.Request) {
	var req submitRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "chain.bad_request", "invalid JSON body", nil)
		return
	}
	result, err := h.svc.SubmitClassic(r.Context(), req.XDR)
	if err != nil {
		writeChainError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, result)
}

func (h *Handler) SubmitSoroban(w http.ResponseWriter, r *http.Request) {
	var req submitRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "chain.bad_request", "invalid JSON body", nil)
		return
	}
	result, err := h.svc.SubmitSoroban(r.Context(), req.XDR)
	if err != nil {
		writeChainError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, result)
}

type fundRequest struct {
	Address string `json:"address"`
}

// Fund is testnet-only (Stellar's friendbot has no mainnet equivalent);
// pay-chain-gateway itself does not gate this by network — the deploy
// profile simply never points FUND at anything but testnet Horizon.
func (h *Handler) Fund(w http.ResponseWriter, r *http.Request) {
	var req fundRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "chain.bad_request", "invalid JSON body", nil)
		return
	}
	if err := h.svc.Fund(r.Context(), req.Address); err != nil {
		writeChainError(w, err)
		return
	}
	httpx.WriteData(w, http.StatusOK, map[string]bool{"funded": true})
}

func writeChainError(w http.ResponseWriter, err error) {
	if errors.Is(err, ErrSorobanDisabled) {
		httpx.WriteError(w, http.StatusServiceUnavailable, "chain.soroban_disabled", "Soroban RPC is not configured on this deployment", nil)
		return
	}
	httpx.WriteError(w, http.StatusBadGateway, "chain.rpc_unavailable", err.Error(), nil)
}
