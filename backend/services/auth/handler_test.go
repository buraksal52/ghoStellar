package auth

import (
	"bytes"
	"context"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/stellar/go-stellar-sdk/keypair"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/httpx"
	"github.com/local-payment/backend/ports/portstest"
)

func TestHandler_Challenge_InvalidAccountRejected(t *testing.T) {
	svc, _ := testServiceAndServer(t)
	h := NewHandler(svc)

	req := httptest.NewRequest("GET", "/auth/challenge?account=not-an-address", nil)
	rec := httptest.NewRecorder()
	h.Challenge(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got status %d, want 400", rec.Code)
	}
}

func TestHandler_Challenge_ValidAccountReturnsTransaction(t *testing.T) {
	svc, _ := testServiceAndServer(t)
	h := NewHandler(svc)
	clientKP, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest("GET", "/auth/challenge?account="+clientKP.Address(), nil)
	rec := httptest.NewRecorder()
	h.Challenge(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d, body=%s", rec.Code, rec.Body.String())
	}
	var env struct {
		Data struct {
			Transaction string `json:"transaction"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Data.Transaction == "" {
		t.Error("expected a non-empty challenge transaction")
	}
}

func TestHandler_Token_HappyPathAndBadSignature(t *testing.T) {
	svc, _ := testServiceAndServer(t)
	h := NewHandler(svc)
	clientKP, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	unsignedXDR, err := svc.Challenge(clientKP.Address())
	if err != nil {
		t.Fatal(err)
	}

	t.Run("valid signature", func(t *testing.T) {
		signedXDR := signChallenge(t, unsignedXDR, clientKP)
		body, _ := json.Marshal(tokenRequest{Transaction: signedXDR})
		req := httptest.NewRequest("POST", "/auth/token", bytes.NewReader(body))
		rec := httptest.NewRecorder()
		h.Token(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("got status %d, body=%s", rec.Code, rec.Body.String())
		}
	})

	t.Run("missing transaction field", func(t *testing.T) {
		req := httptest.NewRequest("POST", "/auth/token", bytes.NewReader([]byte(`{}`)))
		rec := httptest.NewRecorder()
		h.Token(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("got status %d, want 400", rec.Code)
		}
	})

	t.Run("wrong signer", func(t *testing.T) {
		impostor, err := keypair.Random()
		if err != nil {
			t.Fatal(err)
		}
		signedXDR := signChallenge(t, unsignedXDR, impostor)
		body, _ := json.Marshal(tokenRequest{Transaction: signedXDR})
		req := httptest.NewRequest("POST", "/auth/token", bytes.NewReader(body))
		rec := httptest.NewRecorder()
		h.Token(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("got status %d, want 401", rec.Code)
		}
	})
}

func TestHandler_Token_RepositoryFailureIsNotReportedAsBadSignature(t *testing.T) {
	repo := newFakeRepo()
	repo.failOn["UpsertUser"] = errors.New("database unavailable")
	svc, _ := testServiceAndServerWithRepo(t, repo)
	h := NewHandler(svc)
	clientKP, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	unsignedXDR, err := svc.Challenge(clientKP.Address())
	if err != nil {
		t.Fatalf("Challenge: %v", err)
	}
	signedXDR := signChallenge(t, unsignedXDR, clientKP)
	body, _ := json.Marshal(tokenRequest{Transaction: signedXDR})
	req := httptest.NewRequest("POST", "/auth/token", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	h.Token(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("got status %d, want 500", rec.Code)
	}
}

func TestHandler_Refresh_MissingTokenRejected(t *testing.T) {
	svc, _ := testServiceAndServer(t)
	h := NewHandler(svc)

	req := httptest.NewRequest("POST", "/auth/refresh", bytes.NewReader([]byte(`{}`)))
	rec := httptest.NewRecorder()
	h.Refresh(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got status %d, want 400", rec.Code)
	}
}

func TestHandler_Me_NoClaimsRejected(t *testing.T) {
	svc, _ := testServiceAndServer(t)
	h := NewHandler(svc)

	req := httptest.NewRequest("GET", "/auth/me", nil)
	rec := httptest.NewRecorder()
	h.Me(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got status %d, want 401", rec.Code)
	}
}

func TestHandler_Me_WithClaims(t *testing.T) {
	repo := newFakeRepo()
	svc, _ := testServiceAndServerWithRepo(t, repo)
	h := NewHandler(svc)

	address := "GADDRXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
	if _, err := repo.UpsertUser(context.Background(), address); err != nil {
		t.Fatal(err)
	}

	priv, _ := testJWTKeys(t)
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

	mux := http.NewServeMux()
	RegisterProtectedRoutes(mux, h)
	protected := authx.RequireBearer(&priv.PublicKey, "", func(w http.ResponseWriter) {
		httpx.WriteError(w, http.StatusUnauthorized, ErrInvalidToken, "missing bearer claims", nil)
	}, mux)

	req := httptest.NewRequest("GET", "/auth/me", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	protected.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d, body=%s", rec.Code, rec.Body.String())
	}
}

// testServiceAndServerWithRepo is testServiceAndServer but lets the caller
// keep a handle on the fake repo to seed it beforehand.
func testServiceAndServerWithRepo(t *testing.T, repo authRepo) (*Service, *keypair.Full) {
	t.Helper()
	serverKP, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	priv, pub := testJWTKeys(t)
	cfg := Config{
		ServerSigningSeed: serverKP.Seed(),
		HomeDomain:        "example.com",
		WebAuthDomain:     "example.com",
		NetworkPassphrase: testPassphrase,
		JWTPrivateKey:     priv,
		JWTPublicKey:      pub,
	}
	return newServiceWithRepo(cfg, repo, nil, discardLogger()), serverKP
}

// ---- Fund (the manual "Fund with testnet XLM" action) ----------------------

// authedRequest builds a bearer-protected mux around h and a matching signed
// token for address — the shared setup every Fund test needs.
func authedRequest(t *testing.T, h *Handler, priv *rsa.PrivateKey, address string) (http.Handler, string) {
	t.Helper()
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
	mux := http.NewServeMux()
	RegisterProtectedRoutes(mux, h)
	protected := authx.RequireBearer(&priv.PublicKey, "", func(w http.ResponseWriter) {
		httpx.WriteError(w, http.StatusUnauthorized, ErrInvalidToken, "missing bearer claims", nil)
	}, mux)
	return protected, tok
}

func TestHandler_Fund_RequiresBearer(t *testing.T) {
	svc, _ := testServiceAndServer(t)
	h := NewHandler(svc)

	req := httptest.NewRequest("POST", "/auth/fund", nil)
	rec := httptest.NewRecorder()
	h.Fund(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got status %d, want 401", rec.Code)
	}
}

func TestHandler_Fund_FundsTheCallersOwnAddress(t *testing.T) {
	priv, _ := testJWTKeys(t)
	address := "GADDRXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
	chain := &portstest.FakeChain{}
	svc, _ := testServiceAndServerWithChain(t, chain, true)
	h := NewHandler(svc)
	mux, tok := authedRequest(t, h, priv, address)

	req := httptest.NewRequest("POST", "/auth/fund", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d, body=%s", rec.Code, rec.Body.String())
	}
	var env struct {
		Data struct {
			Funded bool `json:"funded"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !env.Data.Funded {
		t.Error("funded = false, want true")
	}
	if chain.FundCalls != 1 {
		t.Errorf("FundCalls = %d, want 1", chain.FundCalls)
	}
}

func TestHandler_Fund_ReportsFalseWithoutErroringWhenUnavailable(t *testing.T) {
	priv, _ := testJWTKeys(t)
	svc, _ := testServiceAndServer(t) // FundNewAccounts=false (e.g. mainnet)
	h := NewHandler(svc)
	mux, tok := authedRequest(t, h, priv, "GADDR")

	req := httptest.NewRequest("POST", "/auth/fund", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d, want 200 even when funding is unavailable, body=%s", rec.Code, rec.Body.String())
	}
	var env struct {
		Data struct {
			Funded bool `json:"funded"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Data.Funded {
		t.Error("funded = true, want false")
	}
}
