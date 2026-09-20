package chain

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stellar/go-stellar-sdk/clients/horizonclient"
	"github.com/stellar/go-stellar-sdk/protocols/horizon"
	"github.com/stellar/go-stellar-sdk/protocols/horizon/base"

	"github.com/local-payment/backend/pkg/nethost"
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

// ---- Fund (friendbot) -------------------------------------------------------
//
// Fund calls FriendbotURL directly through the injected *http.Client, so —
// unlike the Horizon/Soroban SDK paths above — it is fully testable with a
// plain httptest server.

func TestFund_DisabledWhenFriendbotURLEmpty(t *testing.T) {
	svc := NewService(Config{HorizonURL: "http://127.0.0.1:1"}, nil)
	if err := svc.Fund(context.Background(), "GADDR"); !errors.Is(err, ErrFundingDisabled) {
		t.Fatalf("got %v, want ErrFundingDisabled", err)
	}
}

func TestFund_CallsFriendbotWithAddress(t *testing.T) {
	var gotMethod, gotAddr string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotAddr = r.Method, r.URL.Query().Get("addr")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	svc := NewService(Config{FriendbotURL: srv.URL}, srv.Client())
	if err := svc.Fund(context.Background(), "GADDR123"); err != nil {
		t.Fatalf("Fund: %v", err)
	}
	if gotMethod != http.MethodGet || gotAddr != "GADDR123" {
		t.Errorf("friendbot saw %s addr=%q, want GET addr=GADDR123", gotMethod, gotAddr)
	}
}

func TestFund_NonSuccessStatusIsAnErrorCarryingTheBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "op_already_exists", http.StatusBadRequest)
	}))
	defer srv.Close()

	svc := NewService(Config{FriendbotURL: srv.URL}, srv.Client())
	err := svc.Fund(context.Background(), "GADDR")
	if err == nil {
		t.Fatal("expected an error for a 400 from friendbot")
	}
	if !strings.Contains(err.Error(), "400") || !strings.Contains(err.Error(), "op_already_exists") {
		t.Errorf("error %q should carry the status and friendbot's message", err)
	}
}

func TestFund_HonorsContextDeadline(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(10 * time.Second):
		}
	}))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	err := NewService(Config{FriendbotURL: srv.URL}, srv.Client()).Fund(ctx, "GADDR")
	if err == nil {
		t.Fatal("expected a deadline error")
	}
	if time.Since(start) > 5*time.Second {
		t.Errorf("Fund ignored its context: took %s", time.Since(start))
	}
}

// TestFund_AllowListedFriendbotHostIsReachable is the production wiring: the
// chain client is a nethost.Client whose allow-list carries the friendbot
// host, and a call to a host NOT on it is refused.
func TestFund_AllowListedFriendbotHostIsReachable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	host, _, err := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}

	allowed := NewService(Config{FriendbotURL: srv.URL}, nethost.Client(nethost.AllowList{host: true}))
	if err := allowed.Fund(context.Background(), "GADDR"); err != nil {
		t.Fatalf("Fund with friendbot host allow-listed: %v", err)
	}

	blocked := NewService(Config{FriendbotURL: srv.URL}, nethost.Client(nethost.AllowList{"horizon.example": true}))
	if err := blocked.Fund(context.Background(), "GADDR"); err == nil || !strings.Contains(err.Error(), "not allow-listed") {
		t.Fatalf("got %v, want a host-not-allow-listed error", err)
	}
}

// TestHorizonSDKFund_RedirectToUnlistedHostIsBlocked pins WHY Fund no longer
// goes through horizonclient.Client.Fund: Horizon answers /friendbot with a
// 307 to friendbot.stellar.org, and nethost checks every redirect hop, so
// with only Horizon on the allow-list the SDK path can never succeed.
func TestHorizonSDKFund_RedirectToUnlistedHostIsBlocked(t *testing.T) {
	fakeHorizon := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://friendbot.invalid/?addr="+r.URL.Query().Get("addr"), http.StatusTemporaryRedirect)
	}))
	defer fakeHorizon.Close()
	host, _, err := net.SplitHostPort(strings.TrimPrefix(fakeHorizon.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}

	c := &horizonclient.Client{HorizonURL: fakeHorizon.URL, HTTP: nethost.Client(nethost.AllowList{host: true})}
	_, err = c.Fund("GADDR")
	if err == nil || !strings.Contains(err.Error(), "not allow-listed") {
		t.Fatalf("got %v, want the redirect hop to be refused by the allow-list", err)
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
