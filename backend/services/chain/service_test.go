package chain

import (
	"context"
	"testing"

	"github.com/stellar/go-stellar-sdk/protocols/horizon"
	"github.com/stellar/go-stellar-sdk/protocols/horizon/base"

	"github.com/local-payment/backend/ports"
)

// ---- Soroban-disabled fallback (architecture.md §4.6: "boş env var =
// özellik kapalı") ----------------------------------------------------------
//
// horizonclient.Client and rpcclient.Client are concrete SDK types with no
// seam this package can substitute in-process — testing the live Horizon/
// Soroban RPC wire protocol here would mean hand-emulating a large surface
// of their JSON shapes, which risks tests that assert an incidental
// implementation detail rather than a real contract. The behavior that IS
// entirely ours, and worth locking down without any network, is the
// SorobanRPCURL-empty fallback and the pure toBalances helper below.

func TestSimulateTransaction_SorobanDisabled(t *testing.T) {
	svc := NewService(Config{HorizonURL: "http://127.0.0.1:1"}, nil)
	_, err := svc.SimulateTransaction(context.Background(), "AAAA==")
	if err != ErrSorobanDisabled {
		t.Fatalf("got %v, want ErrSorobanDisabled", err)
	}
}

func TestSubmitSoroban_SorobanDisabled(t *testing.T) {
	svc := NewService(Config{HorizonURL: "http://127.0.0.1:1"}, nil)
	_, err := svc.SubmitSoroban(context.Background(), "AAAA==")
	if err != ErrSorobanDisabled {
		t.Fatalf("got %v, want ErrSorobanDisabled", err)
	}
}

func TestNewService_SorobanEnabledWhenURLSet(t *testing.T) {
	svc := NewService(Config{HorizonURL: "http://127.0.0.1:1", SorobanRPCURL: "https://rpc.example"}, nil)
	if svc.rpc == nil {
		t.Fatal("expected rpc client to be constructed when SorobanRPCURL is set")
	}
}

// ---- toBalances -------------------------------------------------------------

func TestToBalances(t *testing.T) {
	in := []horizon.Balance{
		{Balance: "100.0000000", Asset: base.Asset{Type: "native"}},
		{Balance: "50.0000000", Limit: "1000.0000000", Asset: base.Asset{Type: "credit_alphanum4", Code: "USDC", Issuer: "GISSUER"}},
	}
	out := toBalances(in)
	if len(out) != 2 {
		t.Fatalf("got %d balances, want 2", len(out))
	}
	if out[0].AssetCode != "native" || out[0].Balance != "100.0000000" {
		t.Errorf("native balance = %+v", out[0])
	}
	if out[1].AssetCode != "USDC" || out[1].AssetIssuer != "GISSUER" || out[1].Limit != "1000.0000000" {
		t.Errorf("credit balance = %+v", out[1])
	}
}

func TestToBalances_Empty(t *testing.T) {
	out := toBalances(nil)
	if len(out) != 0 {
		t.Fatalf("got %d balances, want 0", len(out))
	}
}

var _ ports.ChainGateway = (*Service)(nil) // documents the compile-time assertion this package relies on
