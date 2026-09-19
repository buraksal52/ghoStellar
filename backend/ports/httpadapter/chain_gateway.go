// Package httpadapter implements every port over internal HTTP to the
// owning microservice, carrying X-Internal-Api-Key
// (docs/reference/platform/architecture.md §4.1, §10). This is the
// microservice profile's wiring; directadapter is monolith's.
package httpadapter

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"

	"github.com/local-payment/backend/ports"
)

// ChainGateway calls pay-chain-gateway's /internal/* routes.
type ChainGateway struct {
	baseURL     string
	internalKey string
	hc          *http.Client
}

var _ ports.ChainGateway = (*ChainGateway)(nil)

func NewChainGateway(baseURL, internalKey string, hc *http.Client) *ChainGateway {
	if hc == nil {
		hc = http.DefaultClient
	}
	return &ChainGateway{baseURL: baseURL, internalKey: internalKey, hc: hc}
}

func (a *ChainGateway) do(ctx context.Context, method, path string, body, out any) error {
	var reqBody *bytes.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("httpadapter: marshal request: %w", err)
		}
		reqBody = bytes.NewReader(b)
	} else {
		reqBody = bytes.NewReader(nil)
	}
	req, err := http.NewRequestWithContext(ctx, method, a.baseURL+path, reqBody)
	if err != nil {
		return fmt.Errorf("httpadapter: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Internal-Api-Key", a.internalKey)

	resp, err := a.hc.Do(req)
	if err != nil {
		return fmt.Errorf("httpadapter: %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		var errBody struct {
			Error struct {
				Code    string `json:"code"`
				Message string `json:"message"`
			} `json:"error"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&errBody)
		if errBody.Error.Code != "" {
			return &Error{Code: errBody.Error.Code, Message: errBody.Error.Message, Status: resp.StatusCode}
		}
		return fmt.Errorf("httpadapter: %s %s: status %d", method, path, resp.StatusCode)
	}

	if out == nil {
		return nil
	}
	var envelope struct {
		Data json.RawMessage `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return fmt.Errorf("httpadapter: decode envelope: %w", err)
	}
	return json.Unmarshal(envelope.Data, out)
}

// Error carries the error.code from a downstream service's envelope so
// callers can branch on it just as they would on a local error, per the
// "frontend her zaman error.code'a bakar" rule extended to service-to-
// service calls.
type Error struct {
	Code    string
	Message string
	Status  int
}

func (e *Error) Error() string { return fmt.Sprintf("%s: %s", e.Code, e.Message) }

func (a *ChainGateway) GetAccount(ctx context.Context, address string) (ports.AccountInfo, error) {
	var out ports.AccountInfo
	err := a.do(ctx, http.MethodGet, "/internal/accounts/"+url.PathEscape(address), nil, &out)
	return out, err
}

func (a *ChainGateway) GetTrustline(ctx context.Context, address, assetCode, assetIssuer string) (ports.TrustlineInfo, error) {
	q := url.Values{"code": {assetCode}, "issuer": {assetIssuer}}
	var out ports.TrustlineInfo
	err := a.do(ctx, http.MethodGet, "/internal/accounts/"+url.PathEscape(address)+"/trustline?"+q.Encode(), nil, &out)
	return out, err
}

func (a *ChainGateway) GetLedger(ctx context.Context) (ports.LedgerInfo, error) {
	var out ports.LedgerInfo
	err := a.do(ctx, http.MethodGet, "/internal/ledger", nil, &out)
	return out, err
}

func (a *ChainGateway) SimulateTransaction(ctx context.Context, unsignedXDR string) (ports.SimulateResult, error) {
	var out ports.SimulateResult
	err := a.do(ctx, http.MethodPost, "/internal/soroban/simulate", map[string]string{"xdr": unsignedXDR}, &out)
	return out, err
}

func (a *ChainGateway) SubmitClassic(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
	var out ports.SubmitResult
	err := a.do(ctx, http.MethodPost, "/internal/submit/classic", map[string]string{"xdr": signedXDR}, &out)
	return out, err
}

func (a *ChainGateway) SubmitSoroban(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
	var out ports.SubmitResult
	err := a.do(ctx, http.MethodPost, "/internal/submit/soroban", map[string]string{"xdr": signedXDR}, &out)
	return out, err
}

func (a *ChainGateway) Fund(ctx context.Context, address string) error {
	return a.do(ctx, http.MethodPost, "/internal/fund", map[string]string{"address": address}, nil)
}
