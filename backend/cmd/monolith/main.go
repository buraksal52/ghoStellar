// pay-monolith: every service in one process, wired with in-process
// (ports/directadapter) gateways instead of internal HTTP — the monolith
// profile SERVICE.md #4 tracked as missing. Route surface, auth, and
// business logic are byte-for-byte the same domain packages the
// microservice binaries use; only the wiring differs. deploy/
// docker-compose.mono.yml runs this instead of the six pay-*-service
// containers.
//
// Deliberately NOT mounted here: pay-chain-gateway's own HTTP handler
// (every caller talks to the in-process chain.Service directly via
// directadapter, so there is nothing for it to answer) and
// pay-cheque-service's /internal/* sweep routes (pay-scheduler-service's
// logic runs as a goroutine in this same process and calls cheque.Service
// directly — see ports/directadapter/scheduler_cheque_gateway.go).
package main

import (
	"context"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/pkg/envx"
	"github.com/local-payment/backend/pkg/httpx"
	"github.com/local-payment/backend/pkg/nethost"
	"github.com/local-payment/backend/pkg/obs"
	"github.com/local-payment/backend/pkg/stellarx"
	"github.com/local-payment/backend/ports/directadapter"
	"github.com/local-payment/backend/services/anchor"
	"github.com/local-payment/backend/services/auth"
	"github.com/local-payment/backend/services/chain"
	"github.com/local-payment/backend/services/cheque"
	"github.com/local-payment/backend/services/scheduler"
	"github.com/local-payment/backend/services/tx"
)

func main() {
	logger := obs.NewLogger("pay-monolith")
	ctx := context.Background()

	privPEM, err := readKey("JWT_PRIVATE_KEY", "JWT_PRIVATE_KEY_PATH", "/secrets/jwt_private.pem")
	if err != nil {
		logger.Error("cannot read JWT private key", "error", err)
		os.Exit(1)
	}
	privKey, err := jwt.ParseRSAPrivateKeyFromPEM(privPEM)
	if err != nil {
		logger.Error("cannot parse JWT private key", "error", err)
		os.Exit(1)
	}
	pubPEM, err := readKey("JWT_PUBLIC_KEY", "JWT_PUBLIC_KEY_PATH", "/secrets/jwt_public.pem")
	if err != nil {
		logger.Error("cannot read JWT public key", "error", err)
		os.Exit(1)
	}
	pubKey, err := authx.ParseRSAPublicKeyPEM(pubPEM)
	if err != nil {
		logger.Error("cannot parse JWT public key", "error", err)
		os.Exit(1)
	}
	webAuthDomain := envx.Get("WEB_AUTH_DOMAIN", "localhost")

	dsn := envx.Get("DATABASE_URL", "postgres://postgres:postgres@localhost:5434/localpayment?sslmode=disable")
	pool := dbx.ConnectAsync(ctx, dsn, logger)

	// ---- chain (in-process, no HTTP) --------------------------------------
	horizonURL := envx.Get("HORIZON_URL", "https://horizon-testnet.stellar.org")
	sorobanURL := envx.Get("SOROBAN_RPC_URL", "https://soroban-testnet.stellar.org")
	// Friendbot is its own host: Horizon's /friendbot only 307-redirects to
	// it, and the allow-list below rejects redirect hops to unlisted hosts.
	friendbotURL := envx.Get("FRIENDBOT_URL", "https://friendbot.stellar.org")
	chainAllow := nethost.AllowList{}
	for _, host := range []string{hostOf(horizonURL), hostOf(sorobanURL), hostOf(friendbotURL)} {
		if host != "" {
			chainAllow[host] = true
		}
	}
	chainSvc := chain.NewService(chain.Config{HorizonURL: horizonURL, SorobanRPCURL: sorobanURL, FriendbotURL: friendbotURL}, nethost.Client(chainAllow))
	chainGW := directadapter.NewChainGateway(chainSvc)

	// ---- auth ---------------------------------------------------------------
	authNetworkPassphrase := envx.Get("NETWORK_PASSPHRASE", stellarx.TestNetworkPassphrase)
	authSvc := auth.NewService(auth.Config{
		ServerSigningSeed: envx.MustGet("SEP10_SIGNING_SEED"),
		HomeDomain:        envx.Get("HOME_DOMAIN", "localhost"),
		WebAuthDomain:     webAuthDomain,
		NetworkPassphrase: authNetworkPassphrase,
		JWTPrivateKey:     privKey,
		JWTPublicKey:      pubKey,
		FundNewAccounts:   shouldFundNewAccounts(authNetworkPassphrase),
	}, pool, chainGW, logger)
	authHandler := auth.NewHandler(authSvc)

	// ---- cheque ---------------------------------------------------------------
	chequeSvc := cheque.NewService(cheque.Config{
		EscrowContractID:  envx.MustGet("PAY_ESCROW_CONTRACT_ID"),
		TokenContractID:   envx.MustGet("ASSET_SAC_CONTRACT_ID"),
		AssetCode:         envx.Get("ASSET_CODE", "USDC"),
		AssetIssuer:       envx.Get("ASSET_ISSUER", "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5"),
		Decimals:          uint8(envx.GetInt("ASSET_DECIMALS", 7)),
		NetworkPassphrase: envx.Get("NETWORK_PASSPHRASE", stellarx.TestNetworkPassphrase),
	}, pool, chainGW)
	chequeHandler := cheque.NewHandler(chequeSvc)

	// ---- tx ---------------------------------------------------------------
	txSvc := tx.NewService(pool, chainGW)
	txHandler := tx.NewHandler(txSvc)

	// ---- anchor ---------------------------------------------------------------
	anchorDomain := envx.Get("ANCHOR_DOMAIN", "tr-mock-anchor.fly.dev")
	anchorClient := anchor.NewClient(nethost.Client(nethost.AllowList{anchorDomain: true}))
	anchorSvc := anchor.NewService(anchor.Config{
		AnchorID:     envx.Get("ANCHOR_ID", "default"),
		AnchorDomain: anchorDomain,
		AssetCode:    envx.Get("ASSET_CODE", "USDC"),
		AssetIssuer:  envx.Get("ASSET_ISSUER", "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5"),
		Decimals:     uint8(envx.GetInt("ASSET_DECIMALS", 7)),
	}, pool, anchorClient, chainGW, logger)
	anchorHandler := anchor.NewHandler(anchorSvc, logger)

	// ---- scheduler (background jobs only, no HTTP routes) -----------------
	schedulerSvc, err := scheduler.NewService(scheduler.Config{
		EscrowContractID:  envx.MustGet("PAY_ESCROW_CONTRACT_ID"),
		NetworkPassphrase: envx.Get("NETWORK_PASSPHRASE", stellarx.TestNetworkPassphrase),
		KeeperSeed:        envx.MustGet("KEEPER_SECRET_SEED"),
	}, chainGW, directadapter.NewSchedulerChequeGateway(chequeSvc), logger)
	if err != nil {
		logger.Error("cannot start scheduler", "error", err)
		os.Exit(1)
	}
	sweepInterval := time.Duration(envx.GetInt("SWEEP_INTERVAL_SECONDS", 60)) * time.Second
	bumpInterval := time.Duration(envx.GetInt("BUMP_INTERVAL_SECONDS", 6*3600)) * time.Second
	go runLoop(ctx, sweepInterval, schedulerSvc.SweepExpiredCheques)
	go runLoop(ctx, bumpInterval, func(ctx context.Context) {
		if err := schedulerSvc.BumpEscrowInstance(ctx); err != nil {
			logger.Warn("bump_instance failed", "error", err)
		}
	})

	// ---- single HTTP surface -----------------------------------------------
	mux := http.NewServeMux()
	// db_ready reflects the one shared pool every DB-backed service here
	// depends on — there is only one pool in the monolith, so one flag
	// suffices (each microservice's own /health only ever reported its own
	// pool anyway).
	mux.Handle("GET /health", httpx.HealthHandler(pool.Ready))

	authAPI := http.NewServeMux()
	auth.RegisterRoutes(authAPI, authHandler)
	authProtectedMux := http.NewServeMux()
	auth.RegisterProtectedRoutes(authProtectedMux, authHandler)
	authProtected := authx.RequireBearer(pubKey, webAuthDomain, unauthorized, authProtectedMux)
	for _, p := range auth.ProtectedPaths() {
		authAPI.Handle(p, authProtected)
	}
	mux.Handle("/auth/", dbx.RequireReady(pool, "auth.db_not_ready", authAPI))

	chequeAPI := http.NewServeMux()
	cheque.RegisterRoutes(chequeAPI, chequeHandler)
	chequeProtected := authx.RequireBearer(pubKey, webAuthDomain, unauthorized, chequeAPI)
	mux.Handle("/", dbx.RequireReady(pool, cheque.ErrDBNotReady, chequeProtected))

	txAPI := http.NewServeMux()
	tx.RegisterRoutes(txAPI, txHandler)
	txProtected := authx.RequireBearer(pubKey, webAuthDomain, unauthorized, txAPI)
	mux.Handle("/tx/", dbx.RequireReady(pool, tx.ErrDBNotReady, txProtected))

	anchorAPI := http.NewServeMux()
	anchor.RegisterRoutes(anchorAPI, anchorHandler)
	anchorProtected := authx.RequireBearer(pubKey, webAuthDomain, unauthorized, anchorAPI)
	mux.Handle("/anchors/", dbx.RequireReady(pool, anchor.ErrDBNotReady, anchorProtected))
	mux.Handle("/anchors", dbx.RequireReady(pool, anchor.ErrDBNotReady, anchorProtected)) // GET /anchors (no segment) — same radix-tree gap as apisix.yaml (SERVICE.md #19a)

	// Railway assigns the listening port at runtime. The explicit wildcard
	// host makes the service reachable through the container network; the
	// LISTEN_ADDR override keeps the local Compose profile configurable.
	addr := envx.Get("LISTEN_ADDR", "0.0.0.0:"+envx.Get("PORT", "8080"))
	logger.Info("listening", "addr", addr, "mode", "monolith")
	root := httpx.WithRequestID(httpx.AccessLog(logger, httpx.Recover(logger, httpx.MaxBody(1<<20, mux))))
	writeTimeout := time.Duration(envx.GetInt("HTTP_WRITE_TIMEOUT_SECONDS", 60)) * time.Second
	if err := httpx.ListenAndServe(ctx, addr, root, logger, httpx.ServeOptions{WriteTimeout: writeTimeout}); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

// readKey accepts mounted secret files for Compose and secret environment
// variables for platforms such as Railway.
func readKey(envName, pathEnv, defaultPath string) ([]byte, error) {
	if value := os.Getenv(envName); value != "" {
		return []byte(value), nil
	}
	return os.ReadFile(envx.Get(pathEnv, defaultPath))
}

func unauthorized(w http.ResponseWriter) {
	httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing or invalid bearer token", nil)
}

// shouldFundNewAccounts controls the best-effort testnet friendbot fund on
// first login (SERVICE.md #24) — see cmd/authsvc's identical helper for the
// rationale (kept duplicated rather than shared: cmd/* packages are each
// main, not a library).
func shouldFundNewAccounts(networkPassphrase string) bool {
	if v := envx.Get("FUND_NEW_ACCOUNTS", ""); v != "" {
		b, err := strconv.ParseBool(v)
		if err == nil {
			return b
		}
	}
	return networkPassphrase == stellarx.TestNetworkPassphrase
}

func hostOf(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	return u.Hostname()
}

func runLoop(ctx context.Context, interval time.Duration, fn func(context.Context)) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			fn(ctx)
		}
	}
}
