package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/stellar/go-stellar-sdk/keypair"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/httpx"
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
	protected := authx.RequireBearer(&priv.PublicKey, func(w http.ResponseWriter) {
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
	return newServiceWithRepo(cfg, repo), serverKP
}
