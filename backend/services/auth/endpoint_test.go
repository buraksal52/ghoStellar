package auth

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/httpx"
)

// TestProtectedPaths_MatchesEveryPathMountedByMainGo guards against the
// exact regression that made POST /auth/fund 404 in production: the
// outer mux (api/authAPI in cmd/authsvc and cmd/monolith) must mount the
// guarded sub-mux on every path RegisterProtectedRoutes serves, not just
// one. This wires the outer/inner mux pair the same way both main.go
// files do — one http.Handle per entry in ProtectedPaths — and asserts
// no protected path 404s and none of them are reachable without a bearer
// token.
func TestProtectedPaths_MatchesEveryPathMountedByMainGo(t *testing.T) {
	const address = "GADDRXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
	repo := newFakeRepo()
	if _, err := repo.UpsertUser(context.Background(), address); err != nil {
		t.Fatal(err)
	}
	svc, _ := testServiceAndServerWithRepo(t, repo)
	h := NewHandler(svc)
	priv, pub := testJWTKeys(t)

	protectedMux := http.NewServeMux()
	RegisterProtectedRoutes(protectedMux, h)
	protected := authx.RequireBearer(pub, "", func(w http.ResponseWriter) {
		httpx.WriteError(w, http.StatusUnauthorized, ErrInvalidToken, "missing bearer claims", nil)
	}, protectedMux)

	// This mirrors cmd/authsvc/main.go and cmd/monolith/main.go: the outer
	// mux only knows about the paths it is explicitly given.
	outer := http.NewServeMux()
	for _, p := range ProtectedPaths() {
		outer.Handle(p, protected)
	}

	methodFor := map[string]string{"/auth/me": "GET", "/auth/fund": "POST"}

	for _, p := range ProtectedPaths() {
		method, ok := methodFor[p]
		if !ok {
			t.Fatalf("test does not know the HTTP method for protected path %q — add it to methodFor", p)
		}

		t.Run(p+"/no_token_is_401_not_404", func(t *testing.T) {
			req := httptest.NewRequest(method, p, nil)
			rec := httptest.NewRecorder()
			outer.ServeHTTP(rec, req)
			if rec.Code == http.StatusNotFound {
				t.Fatalf("outer mux 404'd %s %s — it isn't mounting this ProtectedPaths() entry (the exact authsvc/monolith wiring bug)", method, p)
			}
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("got status %d, want 401 (missing bearer), body=%s", rec.Code, rec.Body.String())
			}
		})

		t.Run(p+"/with_token_is_not_404", func(t *testing.T) {
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

			req := httptest.NewRequest(method, p, nil)
			req.Header.Set("Authorization", "Bearer "+tok)
			rec := httptest.NewRecorder()
			outer.ServeHTTP(rec, req)
			if rec.Code == http.StatusNotFound {
				t.Fatalf("outer mux 404'd authenticated %s %s", method, p)
			}
		})
	}
}
