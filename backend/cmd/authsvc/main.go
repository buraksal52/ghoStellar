// pay-auth-service: SEP-10 challenge/verify + RS256 JWT minting + minimal
// user profile. See docs/reference/platform/architecture.md §5.1, §10.
package main

import (
	"context"
	"net/http"
	"os"

	"github.com/golang-jwt/jwt/v5"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/pkg/envx"
	"github.com/local-payment/backend/pkg/httpx"
	"github.com/local-payment/backend/pkg/obs"
	"github.com/local-payment/backend/services/auth"
)

func main() {
	logger := obs.NewLogger("pay-auth-service")
	ctx := context.Background()

	privPEM, err := os.ReadFile(envx.Get("JWT_PRIVATE_KEY_PATH", "/secrets/jwt_private.pem"))
	if err != nil {
		logger.Error("cannot read JWT private key", "error", err)
		os.Exit(1)
	}
	privKey, err := jwt.ParseRSAPrivateKeyFromPEM(privPEM)
	if err != nil {
		logger.Error("cannot parse JWT private key", "error", err)
		os.Exit(1)
	}
	pubPEM, err := os.ReadFile(envx.Get("JWT_PUBLIC_KEY_PATH", "/secrets/jwt_public.pem"))
	if err != nil {
		logger.Error("cannot read JWT public key", "error", err)
		os.Exit(1)
	}
	pubKey, err := authx.ParseRSAPublicKeyPEM(pubPEM)
	if err != nil {
		logger.Error("cannot parse JWT public key", "error", err)
		os.Exit(1)
	}

	dsn := envx.Get("DATABASE_URL", "postgres://postgres:postgres@localhost:5434/localpayment?sslmode=disable")
	pool := dbx.ConnectAsync(ctx, dsn, logger)

	svc := auth.NewService(auth.Config{
		ServerSigningSeed: envx.MustGet("SEP10_SIGNING_SEED"),
		HomeDomain:        envx.Get("HOME_DOMAIN", "localhost"),
		WebAuthDomain:     envx.Get("WEB_AUTH_DOMAIN", "localhost"),
		NetworkPassphrase: envx.Get("NETWORK_PASSPHRASE", "Test SDF Network ; September 2015"),
		JWTPrivateKey:     privKey,
		JWTPublicKey:      pubKey,
	}, pool)

	handler := auth.NewHandler(svc)

	// /health is registered on the OUTER mux, unguarded by DB readiness —
	// it must answer 200 the instant the process is up so
	// `depends_on: condition: service_healthy` never deadlocks (the async-
	// connect boot pattern, docs/reference/platform/architecture.md's
	// referenced boot patterns).
	mux := http.NewServeMux()
	mux.Handle("GET /health", httpx.HealthHandler(pool.Ready))

	api := http.NewServeMux()
	auth.RegisterRoutes(api, handler)
	protected := http.NewServeMux()
	auth.RegisterProtectedRoutes(protected, handler)
	api.Handle("/auth/me", authx.RequireBearer(pubKey, envx.Get("WEB_AUTH_DOMAIN", "localhost"), unauthorized, protected))
	mux.Handle("/auth/", dbx.RequireReady(pool, "auth.db_not_ready", api))

	addr := envx.Get("LISTEN_ADDR", ":8081")
	logger.Info("listening", "addr", addr)
	root := httpx.WithRequestID(httpx.AccessLog(logger, httpx.Recover(logger, httpx.MaxBody(1<<20, mux))))
	if err := httpx.ListenAndServe(ctx, addr, root, logger, httpx.ServeOptions{}); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func unauthorized(w http.ResponseWriter) {
	httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing or invalid bearer token", nil)
}
