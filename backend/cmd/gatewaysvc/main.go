// pay-chain-gateway: the single Horizon/Soroban RPC exit point for the
// whole backend (docs/reference/platform/architecture.md §4 rule 2). It
// holds no database — it is a stateless proxy with retry/allow-listing.
package main

import (
	"net/http"
	"net/url"
	"os"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/envx"
	"github.com/local-payment/backend/pkg/httpx"
	"github.com/local-payment/backend/pkg/nethost"
	"github.com/local-payment/backend/pkg/obs"
	"github.com/local-payment/backend/services/chain"
)

func main() {
	logger := obs.NewLogger("pay-chain-gateway")

	horizonURL := envx.Get("HORIZON_URL", "https://horizon-testnet.stellar.org")
	sorobanURL := envx.Get("SOROBAN_RPC_URL", "https://soroban-testnet.stellar.org")
	internalKey := envx.Get("INTERNAL_API_KEY", "")
	listenAddr := envx.Get("LISTEN_ADDR", ":8082")

	allow := nethost.AllowList{}
	for _, host := range []string{hostOf(horizonURL), hostOf(sorobanURL)} {
		if host != "" {
			allow[host] = true
		}
	}
	httpClient := nethost.Client(allow)

	svc := chain.NewService(chain.Config{
		HorizonURL:    horizonURL,
		SorobanRPCURL: sorobanURL,
	}, httpClient)
	handler := chain.NewHandler(svc)

	mux := http.NewServeMux()
	mux.Handle("GET /health", httpx.HealthHandler(func() bool { return true }))

	internal := http.NewServeMux()
	chain.RegisterRoutes(internal, handler)
	mux.Handle("/internal/", authx.RequireInternalKey(internalKey, internal))

	logger.Info("listening", "addr", listenAddr, "soroban_enabled", sorobanURL != "")
	if err := http.ListenAndServe(listenAddr, httpx.WithRequestID(mux)); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func hostOf(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	return u.Hostname()
}
