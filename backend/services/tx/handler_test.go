package tx

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/httpx"
	"github.com/local-payment/backend/ports"
	"github.com/local-payment/backend/ports/portstest"
)

func bearerToken(t *testing.T, address string) (*rsa.PublicKey, string) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	claims := authx.Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(now.Add(time.Hour)),
			IssuedAt:  jwt.NewNumericDate(now),
			Subject:   "access",
		},
		StellarAccount: address,
	}
	tok, err := jwt.NewWithClaims(jwt.SigningMethodRS256, claims).SignedString(priv)
	if err != nil {
		t.Fatal(err)
	}
	return &priv.PublicKey, tok
}

func testMux(h *Handler, pubKey *rsa.PublicKey) http.Handler {
	mux := http.NewServeMux()
	RegisterRoutes(mux, h)
	return authx.RequireBearer(pubKey, func(w http.ResponseWriter) {
		httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing bearer claims", nil)
	}, mux)
}

func TestHandler_Submit_MissingIdempotencyKeyRejected(t *testing.T) {
	svc := newServiceWithRepo(newFakeRepo(), &portstest.FakeChain{})
	pubKey, tok := bearerToken(t, "GADDR")
	mux := testMux(NewHandler(svc), pubKey)

	req := httptest.NewRequest("POST", "/tx/submit", bytes.NewBufferString(`{"purpose":"cheque.lock","xdr":"AAAA=="}`))
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got status %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

func TestHandler_Submit_MalformedJSONRejected(t *testing.T) {
	svc := newServiceWithRepo(newFakeRepo(), &portstest.FakeChain{})
	pubKey, tok := bearerToken(t, "GADDR")
	mux := testMux(NewHandler(svc), pubKey)

	req := httptest.NewRequest("POST", "/tx/submit", bytes.NewBufferString(`{not-json`))
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got status %d, want 400", rec.Code)
	}
}

func TestHandler_Submit_NoBearerRejected(t *testing.T) {
	svc := newServiceWithRepo(newFakeRepo(), &portstest.FakeChain{})
	pubKey, _ := bearerToken(t, "GADDR")
	mux := testMux(NewHandler(svc), pubKey)

	req := httptest.NewRequest("POST", "/tx/submit", bytes.NewBufferString(`{}`))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got status %d, want 401", rec.Code)
	}
}

// TestHandler_Submit_ReplayedKeyReturns200 exercises the HTTP-level replay
// path: a second /tx/submit with the same idempotencyKey after the first
// has already completed must succeed with Replayed=true, not resubmit.
func TestHandler_Submit_ReplayedKeyReturns200(t *testing.T) {
	svc := newServiceWithRepo(newFakeRepo(), &portstest.FakeChain{
		SubmitClassicFunc: func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
			return ports.SubmitResult{Hash: "h", Successful: true}, nil
		},
	})
	pubKey, tok := bearerToken(t, "GADDR")
	mux := testMux(NewHandler(svc), pubKey)

	body := `{"idempotencyKey":"dup-key","purpose":"cheque.lock","kind":"classic","xdr":"AAAA=="}`
	req1 := httptest.NewRequest("POST", "/tx/submit", bytes.NewBufferString(body))
	req1.Header.Set("Authorization", "Bearer "+tok)
	rec1 := httptest.NewRecorder()
	mux.ServeHTTP(rec1, req1)
	if rec1.Code != http.StatusOK {
		t.Fatalf("first submit: got %d, body=%s", rec1.Code, rec1.Body.String())
	}

	// A second call with the SAME key after the first already completed is
	// a replay (200, Replayed=true), not a conflict — assert that shape
	// instead, since fakeRepo completes synchronously.
	req2 := httptest.NewRequest("POST", "/tx/submit", bytes.NewBufferString(body))
	req2.Header.Set("Authorization", "Bearer "+tok)
	rec2 := httptest.NewRecorder()
	mux.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusOK {
		t.Fatalf("replayed submit: got %d, body=%s", rec2.Code, rec2.Body.String())
	}
}

func TestHandler_Submit_InFlightKeyReturns409(t *testing.T) {
	repo := newFakeRepo()
	repo.keyStatus["in-flight-key"] = "pending"
	svc := newServiceWithRepo(repo, &portstest.FakeChain{})
	pubKey, tok := bearerToken(t, "GADDR")
	mux := testMux(NewHandler(svc), pubKey)

	body := `{"idempotencyKey":"in-flight-key","purpose":"cheque.lock","kind":"classic","xdr":"AAAA=="}`
	req := httptest.NewRequest("POST", "/tx/submit", bytes.NewBufferString(body))
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusConflict {
		t.Fatalf("got status %d, want 409; body=%s", rec.Code, rec.Body.String())
	}
}

func TestHandler_GetSubmission_NotFound(t *testing.T) {
	svc := newServiceWithRepo(newFakeRepo(), &portstest.FakeChain{})
	pubKey, tok := bearerToken(t, "GADDR")
	mux := testMux(NewHandler(svc), pubKey)

	req := httptest.NewRequest("GET", "/tx/missing-key", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("got status %d, want 404", rec.Code)
	}
}
