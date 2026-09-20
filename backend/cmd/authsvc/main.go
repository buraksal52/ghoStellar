// pay-auth-service: SEP-10 challenge/verify + RS256 JWT minting + minimal
// user profile. See docs/reference/platform/architecture.md §5.1, §10.
package main

import (
	"context"
	"net/http"
	"os"
	"strconv"

	"github.com/golang-jwt/jwt/v5"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/pkg/envx"
	"github.com/local-payment/backend/pkg/httpx"
	"github.com/local-payment/backend/pkg/obs"
	"github.com/local-payment/backend/pkg/stellarx"
	"github.com/local-payment/backend/ports/httpadapter"
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

	networkPassphrase := envx.Get("NETWORK_PASSPHRASE", stellarx.TestNetworkPassphrase)
	chainGW := httpadapter.NewChainGateway(
		envx.Get("CHAIN_GATEWAY_URL", "http://pay-chain-gateway:8082"),
		envx.MustGet("INTERNAL_API_KEY"),
		nil,
	)

	svc := auth.NewService(auth.Config{
		ServerSigningSeed: envx.MustGet("SEP10_SIGNING_SEED"),
		HomeDomain:        envx.Get("HOME_DOMAIN", "localhost"),
		WebAuthDomain:     envx.Get("WEB_AUTH_DOMAIN", "localhost"),
		NetworkPassphrase: networkPassphrase,
		JWTPrivateKey:     privKey,
		JWTPublicKey:      pubKey,
		FundNewAccounts:   shouldFundNewAccounts(networkPassphrase),
	}, pool, chainGW, logger)

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
	protectedMux := http.NewServeMux()
	auth.RegisterProtectedRoutes(protectedMux, handler)
	protected := authx.RequireBearer(pubKey, envx.Get("WEB_AUTH_DOMAIN", "localhost"), unauthorized, protectedMux)
	for _, p := range auth.ProtectedPaths() {
		api.Handle(p, protected)
	}
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

// shouldFundNewAccounts controls the best-effort testnet friendbot fund on
// first login (SERVICE.md #24). FUND_NEW_ACCOUNTS, when set, wins outright;
// otherwise it defaults to on for the well-known testnet passphrase and off
// for anything else (mainnet, a custom passphrase) — mainnet has no
// friendbot, so the code stays inert there without an operator having to
// remember to flip a flag.
func shouldFundNewAccounts(networkPassphrase string) bool {
	if v := envx.Get("FUND_NEW_ACCOUNTS", ""); v != "" {
		b, err := strconv.ParseBool(v)
		if err == nil {
			return b
		}
	}
	return networkPassphrase == stellarx.TestNetworkPassphrase
}
