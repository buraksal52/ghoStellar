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
// RS256 public key and returns its claims. This is the raw verifier — it
// accepts any valid token regardless of its `sub` (access or refresh).
// pay-auth-service's own Refresh flow needs exactly this (it must accept a
// refresh token to mint a new access token). Every other caller wants
// VerifyAccessToken instead — see its doc comment.
//
// expectedAudience, when non-empty, requires the token's `aud` claim to
// contain it (jwt.WithAudience) — SERVICE.md #19. An empty string skips the
// check entirely, which is the safe default for any caller that hasn't
// been updated to pass WEB_AUTH_DOMAIN yet.
func VerifyJWT(token string, publicKey *rsa.PublicKey, expectedAudience string) (Claims, error) {
	opts := []jwt.ParserOption{jwt.WithValidMethods([]string{"RS256"})}
	if expectedAudience != "" {
		opts = append(opts, jwt.WithAudience(expectedAudience))
	}
	var claims Claims
	parsed, err := jwt.ParseWithClaims(token, &claims, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
			return nil, ErrInvalidToken
		}
		return publicKey, nil
	}, opts...)
	if err != nil || !parsed.Valid {
		return Claims{}, ErrInvalidToken
	}
	if claims.StellarAccount == "" {
		return Claims{}, ErrInvalidToken
	}
	return claims, nil
}

// accessTokenSubject is the `sub` claim minted onto access tokens
// (services/auth/service.go's mintPair) — the only subject VerifyAccessToken
// accepts. Kept as a shared constant instead of a magic string on both
// sides of the auth/authx package boundary.
const accessTokenSubject = "access"

// VerifyAccessToken verifies a bearer token AND requires it to be an access
// token, not a refresh token. Access and refresh tokens are signed with the
// same key and both carry a populated StellarAccount, so without this check
// a refresh token — deliberately long-lived (30 days) so the client doesn't
// need to re-sign a SEP-10 challenge often — would work as a bearer token on
// every protected route, defeating the short access-token TTL entirely.
// Fail-closed: a token with an empty or unrecognized `sub` is rejected, not
// just one explicitly marked "refresh".
func VerifyAccessToken(token string, publicKey *rsa.PublicKey, expectedAudience string) (Claims, error) {
	claims, err := VerifyJWT(token, publicKey, expectedAudience)
	if err != nil {
		return Claims{}, err
	}
	if claims.Subject != accessTokenSubject {
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
// decoupled from httpx. Only access tokens are accepted — see
// VerifyAccessToken. expectedAudience is forwarded to VerifyAccessToken
// (SERVICE.md #19); pass "" to skip the aud check (existing behavior).
func RequireBearer(publicKey *rsa.PublicKey, expectedAudience string, onError func(w http.ResponseWriter), next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		token, ok := strings.CutPrefix(auth, "Bearer ")
		if !ok || token == "" {
			onError(w)
			return
		}
		claims, err := VerifyAccessToken(token, publicKey, expectedAudience)
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
