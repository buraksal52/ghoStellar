package httpadapter

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/local-payment/backend/ports"
)

type capturedRequest struct {
	method, path, internalKey string
	body                      []byte
}

func newCaptureServer(t *testing.T, respond func(w http.ResponseWriter, r *http.Request)) (*httptest.Server, *capturedRequest) {
	t.Helper()
	captured := &capturedRequest{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured.method = r.Method
		captured.path = r.URL.Path + "?" + r.URL.RawQuery
		captured.internalKey = r.Header.Get("X-Internal-Api-Key")
		if r.Body != nil {
			captured.body, _ = io.ReadAll(r.Body)
		}
		respond(w, r)
	}))
	t.Cleanup(srv.Close)
	return srv, captured
}

func writeEnvelope(w http.ResponseWriter, data any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"data": data})
}

func TestChainGateway_GetAccount(t *testing.T) {
	srv, captured := newCaptureServer(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, ports.AccountInfo{Address: "GADDR", Sequence: 42, Exists: true})
	})
	gw := NewChainGateway(srv.URL, "internal-secret", nil)

	info, err := gw.GetAccount(context.Background(), "GADDR")
	if err != nil {
		t.Fatalf("GetAccount: %v", err)
	}
	if info.Sequence != 42 || !info.Exists {
		t.Errorf("got %+v", info)
	}
	if captured.method != "GET" || captured.path != "/internal/accounts/GADDR?" {
		t.Errorf("method/path = %s %s", captured.method, captured.path)
	}
	if captured.internalKey != "internal-secret" {
		t.Errorf("X-Internal-Api-Key = %q, want internal-secret", captured.internalKey)
	}
}

func TestChainGateway_GetTrustline_EncodesQuery(t *testing.T) {
	srv, captured := newCaptureServer(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, ports.TrustlineInfo{Exists: true, Balance: "10"})
	})
	gw := NewChainGateway(srv.URL, "k", nil)

	info, err := gw.GetTrustline(context.Background(), "GADDR", "USDC", "GISSUER")
	if err != nil {
		t.Fatalf("GetTrustline: %v", err)
	}
	if !info.Exists || info.Balance != "10" {
		t.Errorf("got %+v", info)
	}
	if captured.path != "/internal/accounts/GADDR/trustline?code=USDC&issuer=GISSUER" {
		t.Errorf("path = %q", captured.path)
	}
}

func TestChainGateway_GetLedger(t *testing.T) {
	srv, captured := newCaptureServer(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, ports.LedgerInfo{Sequence: 100, CloseTime: 123})
	})
	gw := NewChainGateway(srv.URL, "k", nil)
	info, err := gw.GetLedger(context.Background())
	if err != nil {
		t.Fatalf("GetLedger: %v", err)
	}
	if info.Sequence != 100 {
		t.Errorf("got %+v", info)
	}
	if captured.method != "GET" || captured.path != "/internal/ledger?" {
		t.Errorf("method/path = %s %s", captured.method, captured.path)
	}
}

func TestChainGateway_SimulateTransaction_PostsBody(t *testing.T) {
	srv, captured := newCaptureServer(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, ports.SimulateResult{Success: true, MinResourceFee: 5})
	})
	gw := NewChainGateway(srv.URL, "k", nil)
	res, err := gw.SimulateTransaction(context.Background(), "AAAA==")
	if err != nil {
		t.Fatalf("SimulateTransaction: %v", err)
	}
	if !res.Success || res.MinResourceFee != 5 {
		t.Errorf("got %+v", res)
	}
	if captured.method != "POST" || captured.path != "/internal/soroban/simulate?" {
		t.Errorf("method/path = %s %s", captured.method, captured.path)
	}
	var body struct {
		XDR string `json:"xdr"`
	}
	if err := json.Unmarshal(captured.body, &body); err != nil || body.XDR != "AAAA==" {
		t.Errorf("posted body = %s", captured.body)
	}
}

func TestChainGateway_SubmitClassicAndSoroban(t *testing.T) {
	for _, tc := range []struct {
		name string
		call func(gw *ChainGateway) (ports.SubmitResult, error)
		path string
	}{
		{"classic", func(gw *ChainGateway) (ports.SubmitResult, error) {
			return gw.SubmitClassic(context.Background(), "AAAA==")
		}, "/internal/submit/classic?"},
		{"soroban", func(gw *ChainGateway) (ports.SubmitResult, error) {
			return gw.SubmitSoroban(context.Background(), "AAAA==")
		}, "/internal/submit/soroban?"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, captured := newCaptureServer(t, func(w http.ResponseWriter, r *http.Request) {
				writeEnvelope(w, ports.SubmitResult{Hash: "h", Successful: true})
			})
			gw := NewChainGateway(srv.URL, "k", nil)
			res, err := tc.call(gw)
			if err != nil {
				t.Fatalf("%s: %v", tc.name, err)
			}
			if res.Hash != "h" || !res.Successful {
				t.Errorf("got %+v", res)
			}
			if captured.path != tc.path {
				t.Errorf("path = %q, want %q", captured.path, tc.path)
			}
		})
	}
}

func TestChainGateway_Fund(t *testing.T) {
	srv, captured := newCaptureServer(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, map[string]bool{"funded": true})
	})
	gw := NewChainGateway(srv.URL, "k", nil)
	if err := gw.Fund(context.Background(), "GADDR"); err != nil {
		t.Fatalf("Fund: %v", err)
	}
	if captured.method != "POST" || captured.path != "/internal/fund?" {
		t.Errorf("method/path = %s %s", captured.method, captured.path)
	}
}

func TestChainGateway_ErrorEnvelopeSurfacedAsTypedError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"error": map[string]string{"code": "chain.soroban_disabled", "message": "not configured"},
		})
	}))
	defer srv.Close()
	gw := NewChainGateway(srv.URL, "k", nil)

	_, err := gw.GetLedger(context.Background())
	if err == nil {
		t.Fatal("expected an error")
	}
	adapterErr, ok := err.(*Error)
	if !ok {
		t.Fatalf("got %T, want *httpadapter.Error", err)
	}
	if adapterErr.Code != "chain.soroban_disabled" || adapterErr.Status != http.StatusServiceUnavailable {
		t.Errorf("got %+v", adapterErr)
	}
}

func TestChainGateway_NonEnvelopeErrorFallsBackToGenericError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("boom"))
	}))
	defer srv.Close()
	gw := NewChainGateway(srv.URL, "k", nil)

	_, err := gw.GetLedger(context.Background())
	if err == nil {
		t.Fatal("expected an error")
	}
	if _, ok := err.(*Error); ok {
		t.Fatal("expected a plain error, not *httpadapter.Error, for a non-envelope response body")
	}
}
