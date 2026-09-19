// pay-anchor-service: SEP-1/SEP-10(anchor)/SEP-24 proxy + trustline XDR.
// Never stores an anchor's JWT (see
// docs/reference/platform/anchor-entegrasyonu.md).
package main

import (
	"context"
	"net/http"
	"os"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/pkg/envx"
	"github.com/local-payment/backend/pkg/httpx"
	"github.com/local-payment/backend/pkg/nethost"
	"github.com/local-payment/backend/pkg/obs"
	"github.com/local-payment/backend/ports/httpadapter"
	"github.com/local-payment/backend/services/anchor"
)

func main() {
	logger := obs.NewLogger("pay-anchor-service")
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

	anchorDomain := envx.Get("ANCHOR_DOMAIN", "tr-mock-anchor.fly.dev")
	// SSRF allow-list contains ONLY the operator-configured anchor domain —
	// never one derived from a request (architecture.md §10).
	allowedHosts := nethost.AllowList{anchorDomain: true}
	anchorHTTP := nethost.Client(allowedHosts)
	anchorClient := anchor.NewClient(anchorHTTP)

	chainGW := httpadapter.NewChainGateway(
		envx.Get("CHAIN_GATEWAY_URL", "http://pay-chain-gateway:8082"),
		envx.MustGet("INTERNAL_API_KEY"),
		nil,
	)

	svc := anchor.NewService(anchor.Config{
		AnchorID:     envx.Get("ANCHOR_ID", "default"),
		AnchorDomain: anchorDomain,
		AssetCode:    envx.Get("ASSET_CODE", "USDC"),
		AssetIssuer:  envx.Get("ASSET_ISSUER", "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5"),
		Decimals:     uint8(envx.GetInt("ASSET_DECIMALS", 7)),
	}, pool, anchorClient, chainGW, logger)
	handler := anchor.NewHandler(svc, logger)

	mux := http.NewServeMux()
	mux.Handle("GET /health", httpx.HealthHandler(pool.Ready))

	api := http.NewServeMux()
	anchor.RegisterRoutes(api, handler)
	protected := authx.RequireBearer(pubKey, unauthorized, api)
	mux.Handle("/", dbx.RequireReady(pool, anchor.ErrDBNotReady, protected))

	addr := envx.Get("LISTEN_ADDR", ":8086")
	logger.Info("listening", "addr", addr, "anchor_domain", anchorDomain)
	if err := http.ListenAndServe(addr, httpx.WithRequestID(mux)); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func unauthorized(w http.ResponseWriter) {
	httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing or invalid bearer token", nil)
}
