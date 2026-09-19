package directadapter

import (
	"context"
	"net/http"
	"testing"

	"github.com/local-payment/backend/services/chain"
)

// disabledChainService builds a chain.Service with Soroban left off, so the
// Soroban-dependent methods fail deterministically (ErrSorobanDisabled)
// without touching the network — enough to prove directadapter really
// forwards to the wrapped *chain.Service rather than doing anything of its
// own (it has no logic beyond that passthrough).
func disabledChainService() *chain.Service {
	return chain.NewService(chain.Config{HorizonURL: "http://127.0.0.1:1"}, http.DefaultClient)
}

func TestChainGateway_ForwardsSimulateTransaction(t *testing.T) {
	gw := NewChainGateway(disabledChainService())
	_, err := gw.SimulateTransaction(context.Background(), "AAAA==")
	if err != chain.ErrSorobanDisabled {
		t.Fatalf("got %v, want chain.ErrSorobanDisabled", err)
	}
}

func TestChainGateway_ForwardsSubmitSoroban(t *testing.T) {
	gw := NewChainGateway(disabledChainService())
	_, err := gw.SubmitSoroban(context.Background(), "AAAA==")
	if err != chain.ErrSorobanDisabled {
		t.Fatalf("got %v, want chain.ErrSorobanDisabled", err)
	}
}

func TestChainGateway_ForwardsGetAccount(t *testing.T) {
	gw := NewChainGateway(disabledChainService())
	// 127.0.0.1:1 refuses the connection immediately — this only proves the
	// call reaches the wrapped chain.Service (a network error, not a panic
	// or a no-op), not anything about Horizon's real behavior.
	if _, err := gw.GetAccount(context.Background(), "GADDR"); err == nil {
		t.Fatal("expected an error reaching an unroutable Horizon URL")
	}
}
