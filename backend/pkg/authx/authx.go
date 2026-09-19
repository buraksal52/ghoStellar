// Package authx verifies the RS256 JWTs minted by pay-auth-service after a
// successful SEP-10 challenge, and guards internal-only routes with the
// shared X-Internal-Api-Key header.
//
// No service other than pay-auth-service ever holds a private key — every
// other service verifies against the published public key only. See
// docs/reference/platform/architecture.md §10.
package authx

import (
	"context"
	"crypto/rsa"
	"errors"
	"net/http"
	"strings"

	"github.com/golang-jwt/jwt/v5"
)

// ErrInvalidToken covers every way a bearer token can fail verification:
// malformed, wrong algorithm, expired, or bad signature. Handlers translate
// this into the auth.invalid_token / auth.challenge_expired error codes —
// the caller never sees which sub-case occurred (avoids leaking oracle
// information about why a token was rejected).
var ErrInvalidToken = errors.New("authx: invalid or expired token")

// Claims is the JWT payload minted after a successful SEP-10 challenge.
type Claims struct {
	jwt.RegisteredClaims
	StellarAccount string `json:"stellar_account"`
}

// VerifyJWT verifies a bearer token against the auth service's published
// RS256 public key and returns its claims.
func VerifyJWT(token string, publicKey *rsa.PublicKey) (Claims, error) {
	var claims Claims
	parsed, err := jwt.ParseWithClaims(token, &claims, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
			return nil, ErrInvalidToken
		}
		return publicKey, nil
	}, jwt.WithValidMethods([]string{"RS256"}))
	if err != nil || !parsed.Valid {
		return Claims{}, ErrInvalidToken
	}
	if claims.StellarAccount == "" {
		return Claims{}, ErrInvalidToken
	}
	return claims, nil
}

// ParseRSAPublicKeyPEM parses a PEM-encoded RSA public key, as published by
// pay-auth-service and mounted read-only into every other service.
func ParseRSAPublicKeyPEM(pem []byte) (*rsa.PublicKey, error) {
	return jwt.ParseRSAPublicKeyFromPEM(pem)
}

// RequireInternalKey is middleware guarding /internal/* routes with the
// shared X-Internal-Api-Key header. The gateway strips this header from any
// request that did not originate inside the cluster, so its presence here is
// trusted.
func RequireInternalKey(expected string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if expected == "" || r.Header.Get("X-Internal-Api-Key") != expected {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type ctxKey int

const claimsKey ctxKey = 0

// RequireBearer is middleware that verifies the Authorization header on
// user-facing routes and injects Claims into the request context. onError is
// called (envelope + status) when verification fails, so handlers stay
// decoupled from httpx.
func RequireBearer(publicKey *rsa.PublicKey, onError func(w http.ResponseWriter), next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		token, ok := strings.CutPrefix(auth, "Bearer ")
		if !ok || token == "" {
			onError(w)
			return
		}
		claims, err := VerifyJWT(token, publicKey)
		if err != nil {
			onError(w)
			return
		}
		ctx := context.WithValue(r.Context(), claimsKey, claims)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// ClaimsFromContext extracts the Claims injected by RequireBearer.
func ClaimsFromContext(ctx context.Context) (Claims, bool) {
	c, ok := ctx.Value(claimsKey).(Claims)
	return c, ok
}
