package authx

import (
	"crypto/rand"
	"crypto/rsa"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func testKeys(t *testing.T) (*rsa.PrivateKey, *rsa.PublicKey) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return priv, &priv.PublicKey
}

func signToken(t *testing.T, priv *rsa.PrivateKey, subject, account string, expiresIn time.Duration) string {
	t.Helper()
	return signTokenWithAudience(t, priv, subject, account, expiresIn, "")
}

func signTokenWithAudience(t *testing.T, priv *rsa.PrivateKey, subject, account string, expiresIn time.Duration, audience string) string {
	t.Helper()
	now := time.Now()
	claims := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(now.Add(expiresIn)),
			IssuedAt:  jwt.NewNumericDate(now),
			Subject:   subject,
		},
		StellarAccount: account,
	}
	if audience != "" {
		claims.Audience = jwt.ClaimStrings{audience}
	}
	tok, err := jwt.NewWithClaims(jwt.SigningMethodRS256, claims).SignedString(priv)
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

func TestVerifyAccessToken_ValidAccessToken(t *testing.T) {
	priv, pub := testKeys(t)
	tok := signToken(t, priv, "access", "GADDR", time.Hour)

	claims, err := VerifyAccessToken(tok, pub, "")
	if err != nil {
		t.Fatalf("VerifyAccessToken: %v", err)
	}
	if claims.StellarAccount != "GADDR" {
		t.Errorf("got %q, want GADDR", claims.StellarAccount)
	}
}

func TestVerifyAccessToken_RefreshTokenRejected(t *testing.T) {
	priv, pub := testKeys(t)
	tok := signToken(t, priv, "refresh", "GADDR", 30*24*time.Hour)

	if _, err := VerifyAccessToken(tok, pub, ""); err != ErrInvalidToken {
		t.Fatalf("got %v, want ErrInvalidToken", err)
	}
}

func TestVerifyAccessToken_EmptySubjectRejected(t *testing.T) {
	priv, pub := testKeys(t)
	tok := signToken(t, priv, "", "GADDR", time.Hour)

	if _, err := VerifyAccessToken(tok, pub, ""); err != ErrInvalidToken {
		t.Fatalf("got %v, want ErrInvalidToken", err)
	}
}

func TestVerifyAccessToken_UnknownSubjectRejected(t *testing.T) {
	priv, pub := testKeys(t)
	tok := signToken(t, priv, "something-else", "GADDR", time.Hour)

	if _, err := VerifyAccessToken(tok, pub, ""); err != ErrInvalidToken {
		t.Fatalf("got %v, want ErrInvalidToken", err)
	}
}

func TestVerifyAccessToken_ExpiredRejected(t *testing.T) {
	priv, pub := testKeys(t)
	tok := signToken(t, priv, "access", "GADDR", -time.Hour)

	if _, err := VerifyAccessToken(tok, pub, ""); err != ErrInvalidToken {
		t.Fatalf("got %v, want ErrInvalidToken", err)
	}
}

func TestVerifyAccessToken_WrongKeyRejected(t *testing.T) {
	priv, _ := testKeys(t)
	_, otherPub := testKeys(t)
	tok := signToken(t, priv, "access", "GADDR", time.Hour)

	if _, err := VerifyAccessToken(tok, otherPub, ""); err != ErrInvalidToken {
		t.Fatalf("got %v, want ErrInvalidToken", err)
	}
}

func TestVerifyAccessToken_EmptyStellarAccountRejected(t *testing.T) {
	priv, pub := testKeys(t)
	tok := signToken(t, priv, "access", "", time.Hour)

	if _, err := VerifyAccessToken(tok, pub, ""); err != ErrInvalidToken {
		t.Fatalf("got %v, want ErrInvalidToken", err)
	}
}

// TestVerifyJWT_AlgConfusionRejected proves a token signed with a
// symmetric HS256 key (using the RSA public key's bytes as the HMAC
// secret — the classic alg-confusion attack against RS256 verifiers) is
// rejected outright, because VerifyJWT pins the accepted algorithm to
// RS256 via jwt.WithValidMethods.
func TestVerifyJWT_AlgConfusionRejected(t *testing.T) {
	_, pub := testKeys(t)
	claims := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
			Subject:   "access",
		},
		StellarAccount: "GADDR",
	}
	// Sign with HS256 using an arbitrary secret — an attacker doesn't need
	// to know the RSA key at all for this attack; the point is that RS256
	// verification must never fall back to accepting an HS256 token.
	tok, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte("attacker-controlled-secret"))
	if err != nil {
		t.Fatal(err)
	}

	if _, err := VerifyJWT(tok, pub, ""); err != ErrInvalidToken {
		t.Fatalf("got %v, want ErrInvalidToken", err)
	}
}

func TestVerifyJWT_MalformedTokenRejected(t *testing.T) {
	_, pub := testKeys(t)
	if _, err := VerifyJWT("not-a-jwt", pub, ""); err != ErrInvalidToken {
		t.Fatalf("got %v, want ErrInvalidToken", err)
	}
}

func TestVerifyAccessToken_WrongAudienceRejected(t *testing.T) {
	priv, pub := testKeys(t)
	tok := signTokenWithAudience(t, priv, "access", "GADDR", time.Hour, "wrong.example")

	if _, err := VerifyAccessToken(tok, pub, "expected.example"); err != ErrInvalidToken {
		t.Fatalf("got %v, want ErrInvalidToken", err)
	}
}

func TestVerifyAccessToken_MatchingAudienceAccepted(t *testing.T) {
	priv, pub := testKeys(t)
	tok := signTokenWithAudience(t, priv, "access", "GADDR", time.Hour, "expected.example")

	if _, err := VerifyAccessToken(tok, pub, "expected.example"); err != nil {
		t.Fatalf("VerifyAccessToken: %v", err)
	}
}

// TestVerifyAccessToken_EmptyExpectedAudienceSkipsCheck is the backward-
// compatibility guarantee every existing caller relies on: passing "" for
// expectedAudience must accept a token regardless of its aud claim (or
// lack of one).
func TestVerifyAccessToken_EmptyExpectedAudienceSkipsCheck(t *testing.T) {
	priv, pub := testKeys(t)
	tok := signTokenWithAudience(t, priv, "access", "GADDR", time.Hour, "some.random.audience")

	if _, err := VerifyAccessToken(tok, pub, ""); err != nil {
		t.Fatalf("VerifyAccessToken with no expected audience: %v", err)
	}
}

// ---- RequireBearer -----------------------------------------------------------

func TestRequireBearer_NoHeaderRejected(t *testing.T) {
	_, pub := testKeys(t)
	called := false
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true })
	onErr := func(w http.ResponseWriter) { w.WriteHeader(http.StatusUnauthorized) }

	rec := httptest.NewRecorder()
	RequireBearer(pub, "", onErr, next).ServeHTTP(rec, httptest.NewRequest("GET", "/x", nil))

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
	if called {
		t.Error("next handler must not run without a valid bearer token")
	}
}

func TestRequireBearer_EmptyBearerRejected(t *testing.T) {
	_, pub := testKeys(t)
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {})
	onErr := func(w http.ResponseWriter) { w.WriteHeader(http.StatusUnauthorized) }

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/x", nil)
	req.Header.Set("Authorization", "Bearer ")
	RequireBearer(pub, "", onErr, next).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

func TestRequireBearer_ValidTokenInjectsClaims(t *testing.T) {
	priv, pub := testKeys(t)
	tok := signToken(t, priv, "access", "GADDR", time.Hour)

	var gotClaims Claims
	var ok bool
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotClaims, ok = ClaimsFromContext(r.Context())
	})
	onErr := func(w http.ResponseWriter) { w.WriteHeader(http.StatusUnauthorized) }

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/x", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	RequireBearer(pub, "", onErr, next).ServeHTTP(rec, req)

	if !ok {
		t.Fatal("expected claims to be present in context")
	}
	if gotClaims.StellarAccount != "GADDR" {
		t.Errorf("got %q, want GADDR", gotClaims.StellarAccount)
	}
}

func TestClaimsFromContext_AbsentReturnsFalse(t *testing.T) {
	req := httptest.NewRequest("GET", "/x", nil)
	if _, ok := ClaimsFromContext(req.Context()); ok {
		t.Error("expected ok=false when no claims were injected")
	}
}

// ---- RequireInternalKey -------------------------------------------------------

func TestRequireInternalKey(t *testing.T) {
	tests := []struct {
		name       string
		expected   string
		header     string
		wantStatus int
	}{
		{"empty expected always forbidden", "", "anything", http.StatusForbidden},
		{"wrong key forbidden", "secret", "wrong", http.StatusForbidden},
		{"missing header forbidden", "secret", "", http.StatusForbidden},
		{"matching key allowed", "secret", "secret", http.StatusOK},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
			rec := httptest.NewRecorder()
			req := httptest.NewRequest("GET", "/internal/x", nil)
			if tc.header != "" {
				req.Header.Set("X-Internal-Api-Key", tc.header)
			}
			RequireInternalKey(tc.expected, next).ServeHTTP(rec, req)
			if rec.Code != tc.wantStatus {
				t.Errorf("status = %d, want %d", rec.Code, tc.wantStatus)
			}
		})
	}
}
