// pay-tx-service: the single submit point for every signed XDR in the
// backend (docs/reference/platform/architecture.md §4 rule 3).
package main

import (
	"context"
	"net/http"
	"os"
	"time"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/pkg/envx"
	"github.com/local-payment/backend/pkg/httpx"
	"github.com/local-payment/backend/pkg/obs"
	"github.com/local-payment/backend/ports/httpadapter"
	"github.com/local-payment/backend/services/tx"
)

func main() {
	logger := obs.NewLogger("pay-tx-service")
	ctx := context.Background()

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

	chainGW := httpadapter.NewChainGateway(
		envx.Get("CHAIN_GATEWAY_URL", "http://pay-chain-gateway:8082"),
		envx.MustGet("INTERNAL_API_KEY"),
		nil,
	)

	svc := tx.NewService(pool, chainGW)
	handler := tx.NewHandler(svc)

	mux := http.NewServeMux()
	mux.Handle("GET /health", httpx.HealthHandler(pool.Ready))

	api := http.NewServeMux()
	tx.RegisterRoutes(api, handler)
	protected := authx.RequireBearer(pubKey, unauthorized, api)
	mux.Handle("/tx/", dbx.RequireReady(pool, tx.ErrDBNotReady, protected))

	addr := envx.Get("LISTEN_ADDR", ":8084")
	logger.Info("listening", "addr", addr)
	root := httpx.WithRequestID(httpx.Recover(logger, httpx.MaxBody(1<<20, mux)))
	// WriteTimeout is raised above httpx's default: a submit here waits on
	// pay-chain-gateway's own Horizon/Soroban round trip, which can
	// legitimately take longer than the shared default allows.
	writeTimeout := time.Duration(envx.GetInt("HTTP_WRITE_TIMEOUT_SECONDS", 60)) * time.Second
	if err := httpx.ListenAndServe(ctx, addr, root, logger, httpx.ServeOptions{WriteTimeout: writeTimeout}); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func unauthorized(w http.ResponseWriter) {
	httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing or invalid bearer token", nil)
}
