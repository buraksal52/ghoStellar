package chain

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
)

// disabledService builds a Service with Soroban left off (no SorobanRPCURL)
// so every Soroban-dependent handler path is deterministic without a
// network dependency.
func disabledService() *Service {
	return NewService(Config{HorizonURL: "http://127.0.0.1:1"}, http.DefaultClient)
}

func TestHandler_SimulateTransaction_SorobanDisabledMapsTo503(t *testing.T) {
	h := NewHandler(disabledService())
	req := httptest.NewRequest("POST", "/internal/soroban/simulate", bytes.NewBufferString(`{"xdr":"AAAA=="}`))
	rec := httptest.NewRecorder()
	h.SimulateTransaction(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("got status %d, want 503; body=%s", rec.Code, rec.Body.String())
	}
}

func TestHandler_SubmitSoroban_SorobanDisabledMapsTo503(t *testing.T) {
	h := NewHandler(disabledService())
	req := httptest.NewRequest("POST", "/internal/submit/soroban", bytes.NewBufferString(`{"xdr":"AAAA=="}`))
	rec := httptest.NewRecorder()
	h.SubmitSoroban(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("got status %d, want 503; body=%s", rec.Code, rec.Body.String())
	}
}

func TestHandler_MalformedJSONRejected(t *testing.T) {
	h := NewHandler(disabledService())
	tests := []struct {
		name    string
		handler http.HandlerFunc
	}{
		{"SimulateTransaction", h.SimulateTransaction},
		{"SubmitClassic", h.SubmitClassic},
		{"SubmitSoroban", h.SubmitSoroban},
		{"Fund", h.Fund},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", "/x", bytes.NewBufferString(`{not-json`))
			rec := httptest.NewRecorder()
			tc.handler(rec, req)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("got status %d, want 400; body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestHandler_GetTrustline_MissingCodeRejected(t *testing.T) {
	h := NewHandler(disabledService())
	req := httptest.NewRequest("GET", "/internal/accounts/GADDR/trustline", nil)
	req.SetPathValue("address", "GADDR")
	rec := httptest.NewRecorder()
	h.GetTrustline(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got status %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

// TestRegisterRoutes_CoversAllSevenInternalEndpoints proves every internal
// route the plan documents is actually wired and reachable by method+path —
// a mismatch (typo'd path, wrong verb) would 404 instead of reaching the
// handler and failing for a business reason.
func TestRegisterRoutes_CoversAllSevenInternalEndpoints(t *testing.T) {
	h := NewHandler(disabledService())
	mux := http.NewServeMux()
	RegisterRoutes(mux, h)

	routes := []struct{ method, path, body string }{
		{"GET", "/internal/accounts/GADDR", ""},
		{"GET", "/internal/accounts/GADDR/trustline?code=USDC", ""},
		{"GET", "/internal/ledger", ""},
		{"POST", "/internal/soroban/simulate", `{"xdr":"AAAA=="}`},
		{"POST", "/internal/submit/classic", `{"xdr":"AAAA=="}`},
		{"POST", "/internal/submit/soroban", `{"xdr":"AAAA=="}`},
		{"POST", "/internal/fund", `{"address":"GADDR"}`},
	}
	for _, r := range routes {
		t.Run(r.method+" "+r.path, func(t *testing.T) {
			req := httptest.NewRequest(r.method, r.path, bytes.NewBufferString(r.body))
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			// Every route here talks to a live (disabled/unreachable) chain
			// backend, so a 502/503/400 domain error is expected — a 404
			// would mean the route itself isn't registered, which is the
			// one thing this test guards against.
			if rec.Code == http.StatusNotFound {
				t.Fatalf("route not found (got 404) for %s %s", r.method, r.path)
			}
		})
	}
}
