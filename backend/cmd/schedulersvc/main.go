// pay-scheduler-service: sweeps expired cheques into a permissionless
// refund (p2p doc §6.2, §9.B1, D9). No HTTP API of its own beyond /health —
// it triggers work, it does not hold business logic
// (docs/reference/platform/architecture.md §3).
package main

import (
	"context"
	"net/http"
	"os"
	"time"

	"github.com/local-payment/backend/pkg/envx"
	"github.com/local-payment/backend/pkg/httpx"
	"github.com/local-payment/backend/pkg/obs"
	"github.com/local-payment/backend/ports/httpadapter"
	"github.com/local-payment/backend/services/scheduler"
)

func main() {
	logger := obs.NewLogger("pay-scheduler-service")
	ctx := context.Background()

	internalKey := envx.MustGet("INTERNAL_API_KEY")
	chainGW := httpadapter.NewChainGateway(
		envx.Get("CHAIN_GATEWAY_URL", "http://pay-chain-gateway:8082"),
		internalKey,
		nil,
	)
	chequeClient := scheduler.NewChequeClient(
		envx.Get("CHEQUE_SERVICE_URL", "http://pay-cheque-service:8083"),
		internalKey,
		nil,
	)

	svc, err := scheduler.NewService(scheduler.Config{
		EscrowContractID:  envx.MustGet("PAY_ESCROW_CONTRACT_ID"),
		NetworkPassphrase: envx.Get("NETWORK_PASSPHRASE", "Test SDF Network ; September 2015"),
		KeeperSeed:        envx.MustGet("KEEPER_SECRET_SEED"),
	}, chainGW, chequeClient, logger)
	if err != nil {
		logger.Error("cannot start scheduler service", "error", err)
		os.Exit(1)
	}

	sweepInterval := time.Duration(envx.GetInt("SWEEP_INTERVAL_SECONDS", 60)) * time.Second
	bumpInterval := time.Duration(envx.GetInt("BUMP_INTERVAL_SECONDS", 6*3600)) * time.Second

	go runLoop(ctx, sweepInterval, svc.SweepExpiredCheques)
	go runLoop(ctx, bumpInterval, func(ctx context.Context) {
		if err := svc.BumpEscrowInstance(ctx); err != nil {
			logger.Warn("bump_instance failed", "error", err)
		}
	})

	mux := http.NewServeMux()
	mux.Handle("GET /health", httpx.HealthHandler(func() bool { return true }))

	addr := envx.Get("LISTEN_ADDR", ":8085")
	logger.Info("listening", "addr", addr, "sweep_interval", sweepInterval.String())
	if err := http.ListenAndServe(addr, httpx.WithRequestID(mux)); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
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
