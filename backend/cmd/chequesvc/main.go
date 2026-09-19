// pay-cheque-service: the Çek/Havuz state machine, reservation ledger,
// unsigned-XDR production, and Forced Sync. See
// docs/reference/platform/p2p-cek-ve-havuz-mimarisi.md.
package main

import (
	"context"
	"net/http"
	"os"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/pkg/envx"
	"github.com/local-payment/backend/pkg/httpx"
	"github.com/local-payment/backend/pkg/obs"
	"github.com/local-payment/backend/ports/httpadapter"
	"github.com/local-payment/backend/services/cheque"
)

func main() {
	logger := obs.NewLogger("pay-cheque-service")
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

	svc := cheque.NewService(cheque.Config{
		EscrowContractID:  envx.MustGet("PAY_ESCROW_CONTRACT_ID"),
		TokenContractID:   envx.MustGet("ASSET_SAC_CONTRACT_ID"),
		AssetCode:         envx.Get("ASSET_CODE", "USDC"),
		AssetIssuer:       envx.Get("ASSET_ISSUER", "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5"),
		Decimals:          uint8(envx.GetInt("ASSET_DECIMALS", 7)),
		NetworkPassphrase: envx.Get("NETWORK_PASSPHRASE", "Test SDF Network ; September 2015"),
	}, pool, chainGW)
	handler := cheque.NewHandler(svc)

	mux := http.NewServeMux()
	mux.Handle("GET /health", httpx.HealthHandler(pool.Ready))

	api := http.NewServeMux()
	cheque.RegisterRoutes(api, handler)
	protected := authx.RequireBearer(pubKey, unauthorized, api)
	mux.Handle("/", dbx.RequireReady(pool, cheque.ErrDBNotReady, protected))

	internal := http.NewServeMux()
	cheque.RegisterInternalRoutes(internal, cheque.NewInternalHandler(svc))
	mux.Handle("/internal/", authx.RequireInternalKey(envx.MustGet("INTERNAL_API_KEY"), dbx.RequireReady(pool, cheque.ErrDBNotReady, internal)))

	addr := envx.Get("LISTEN_ADDR", ":8083")
	logger.Info("listening", "addr", addr)
	root := httpx.WithRequestID(httpx.Recover(logger, httpx.MaxBody(1<<20, mux)))
	if err := httpx.ListenAndServe(ctx, addr, root, logger, httpx.ServeOptions{}); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func unauthorized(w http.ResponseWriter) {
	httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing or invalid bearer token", nil)
}
