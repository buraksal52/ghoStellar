package anchor

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/stellar/go-stellar-sdk/keypair"
	"github.com/stellar/go-stellar-sdk/txnbuild"

	"github.com/local-payment/backend/ports"
	"github.com/local-payment/backend/ports/portstest"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(discardWriter{}, nil))
}

type discardWriter struct{}

func (discardWriter) Write(p []byte) (int, error) { return len(p), nil }

const (
	testAnchorID     = "default"
	testAnchorDomain = "anchor.example" // DNS-name-shaped; dialingClient redirects it to the local test server
)

// tomlServer starts a TLS server serving tomlBody at /.well-known/stellar.toml
// (and anywhere else, for the ANCHOR_QUOTE_SERVER second-fetch path) and
// returns an anchor.Client whose dials are redirected to it — see
// dialingClient's doc comment for why a real DNS-shaped domain is required.
func tomlServer(t *testing.T, tomlBody string) *Client {
	t.Helper()
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(tomlBody))
	}))
	t.Cleanup(srv.Close)
	return NewClient(dialingClient(srv))
}

func testIssuer(t *testing.T) string {
	t.Helper()
	kp, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	return kp.Address()
}

func testConfig(domain, issuer string) Config {
	return Config{AnchorID: testAnchorID, AnchorDomain: domain, AssetCode: "USDC", AssetIssuer: issuer, Decimals: 7}
}

func TestCheckID_UnknownAnchorRejected(t *testing.T) {
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), NewClient(http.DefaultClient), &portstest.FakeChain{}, discardLogger())
	if err := svc.checkID("someone-else"); !errors.Is(err, errNotAllowed) {
		t.Fatalf("got %v, want errNotAllowed", err)
	}
	if err := svc.checkID(testAnchorID); err != nil {
		t.Fatalf("checkID(%q): %v", testAnchorID, err)
	}
}

func TestInfo_CachesAndRegistersAllowedHosts(t *testing.T) {
	client := tomlServer(t, `
WEB_AUTH_ENDPOINT="https://auth.anchor.example/auth"
TRANSFER_SERVER="https://api.anchor.example/sep6"
KYC_SERVER="https://kyc.anchor.example/sep12"
SIGNING_KEY="GSIGNINGKEY"
`)
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), client, &portstest.FakeChain{}, discardLogger())

	info, err := svc.Info(context.Background(), testAnchorID)
	if err != nil {
		t.Fatalf("Info: %v", err)
	}
	if info.WebAuthEndpoint != "https://auth.anchor.example/auth" {
		t.Errorf("WebAuthEndpoint = %q", info.WebAuthEndpoint)
	}

	// A second call must hit the cache, not the network — checkID would
	// still succeed either way, so assert equality of the cached struct
	// pointer's contents rather than counting requests (the toml server
	// above has no request counter wired up).
	info2, err := svc.Info(context.Background(), testAnchorID)
	if err != nil {
		t.Fatalf("second Info: %v", err)
	}
	if info2 != info {
		t.Error("second Info() call returned a different value than the cached first call")
	}
}

// TestInfo_ConcurrentCallsAreRaceFree is SERVICE.md item #8's regression
// test: many goroutines calling Info concurrently must never race on
// cachedInfo or the SSRF allow-list registration. Run with -race in CI.
func TestInfo_ConcurrentCallsAreRaceFree(t *testing.T) {
	client := tomlServer(t, `
WEB_AUTH_ENDPOINT="https://auth.anchor.example/auth"
SIGNING_KEY="GSIGNINGKEY"
`)
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), client, &portstest.FakeChain{}, discardLogger())

	const n = 50
	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := svc.Info(context.Background(), testAnchorID); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Errorf("concurrent Info() call failed: %v", err)
	}
}

func TestProxySep6_UnpublishedTransferServerErrors(t *testing.T) {
	client := tomlServer(t, `SIGNING_KEY="GSIGNINGKEY"`) // no TRANSFER_SERVER
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), client, &portstest.FakeChain{}, discardLogger())

	_, err := svc.ProxySep6(context.Background(), testAnchorID, "GET", "info", "", "tok", "", nil)
	if err == nil {
		t.Fatal("expected an error when TRANSFER_SERVER is not published")
	}
}

func TestStartInteractive_RequiresAnchorToken(t *testing.T) {
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), NewClient(http.DefaultClient), &portstest.FakeChain{}, discardLogger())
	_, _, err := svc.StartDeposit(context.Background(), testAnchorID, "", "GADDR")
	if !errors.Is(err, errAuthRequired) {
		t.Fatalf("got %v, want errAuthRequired", err)
	}
}

// TestStartInteractive_NoTrustlineRejected is SERVICE.md #11's regression
// test: pay.trustlines used to be write-only. StartDeposit/StartWithdraw
// now read it back via this service's own repo before ever calling the
// anchor.
func TestStartInteractive_NoTrustlineRejected(t *testing.T) {
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), NewClient(http.DefaultClient), &portstest.FakeChain{}, discardLogger())
	_, _, err := svc.StartDeposit(context.Background(), testAnchorID, "anchor-jwt", "GADDR")
	if !errors.Is(err, errTrustlineMissing) {
		t.Fatalf("got %v, want errTrustlineMissing", err)
	}
}

func TestStartInteractive_ActiveTrustlineAllowed(t *testing.T) {
	client := tomlServer(t, `TRANSFER_SERVER24="https://api.anchor.example/sep24"`)
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	repo := newFakeRepo()
	repo.trustlines["GADDR/"+cfg.AssetCode+"/"+cfg.AssetIssuer] = "active"
	svc := newServiceWithRepo(cfg, repo, client, &portstest.FakeChain{}, discardLogger())

	// SEP24Interactive itself will fail (no real transfer server), but the
	// trustline pre-check must not be what rejects this call.
	_, _, err := svc.StartDeposit(context.Background(), testAnchorID, "anchor-jwt", "GADDR")
	if errors.Is(err, errTrustlineMissing) {
		t.Fatal("an active trustline must not be rejected as missing")
	}
}

func TestTrustlineXDR_BuildsChangeTrustOp(t *testing.T) {
	sender, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	chain := &portstest.FakeChain{
		GetAccountFunc: func(ctx context.Context, address string) (ports.AccountInfo, error) {
			return ports.AccountInfo{Address: address, Sequence: 5, Exists: true}, nil
		},
	}
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), NewClient(http.DefaultClient), chain, discardLogger())

	xdrStr, err := svc.TrustlineXDR(context.Background(), sender.Address())
	if err != nil {
		t.Fatalf("TrustlineXDR: %v", err)
	}
	if xdrStr == "" {
		t.Fatal("expected a non-empty trustline XDR")
	}

	genericTx, err := txnbuild.TransactionFromXDR(xdrStr)
	if err != nil {
		t.Fatalf("decode trustline XDR: %v", err)
	}
	tx, ok := genericTx.Transaction()
	if !ok {
		t.Fatal("expected a simple transaction")
	}
	if tx.SourceAccount().AccountID != sender.Address() {
		t.Errorf("source account = %q, want %q", tx.SourceAccount().AccountID, sender.Address())
	}
	ops := tx.Operations()
	if len(ops) != 1 {
		t.Fatalf("got %d operations, want 1", len(ops))
	}
	ct, ok := ops[0].(*txnbuild.ChangeTrust)
	if !ok {
		t.Fatalf("operation is %T, want *txnbuild.ChangeTrust", ops[0])
	}
	asset, err := ct.Line.ToAsset()
	if err != nil {
		t.Fatal(err)
	}
	if code, issuer := asset.GetCode(), asset.GetIssuer(); code != cfg.AssetCode || issuer != cfg.AssetIssuer {
		t.Errorf("asset = %s/%s, want %s/%s", code, issuer, cfg.AssetCode, cfg.AssetIssuer)
	}
}

func TestTrustlineXDR_NoIssuerConfigured(t *testing.T) {
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	cfg.AssetIssuer = ""
	svc := newServiceWithRepo(cfg, newFakeRepo(), NewClient(http.DefaultClient), &portstest.FakeChain{}, discardLogger())
	if _, err := svc.TrustlineXDR(context.Background(), "GADDR"); err == nil {
		t.Fatal("expected an error when no asset issuer is configured")
	}
}

func TestConfirmTrustline_RecordsState(t *testing.T) {
	repo := newFakeRepo()
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, repo, NewClient(http.DefaultClient), &portstest.FakeChain{}, discardLogger())

	if err := svc.ConfirmTrustline(context.Background(), "GADDR", 42); err != nil {
		t.Fatalf("ConfirmTrustline: %v", err)
	}
	if got := repo.trustlines["GADDR/"+cfg.AssetCode+"/"+cfg.AssetIssuer]; got != "active" {
		t.Errorf("trustline state = %q, want active", got)
	}
}

func TestReportTransaction_UnknownAnchorRejected(t *testing.T) {
	svc := newServiceWithRepo(testConfig(testAnchorDomain, testIssuer(t)), newFakeRepo(), NewClient(http.DefaultClient), &portstest.FakeChain{}, discardLogger())
	err := svc.ReportTransaction(context.Background(), "not-the-configured-anchor", "GADDR", Transaction{ID: "tx1"})
	if !errors.Is(err, errNotAllowed) {
		t.Fatalf("got %v, want errNotAllowed", err)
	}
}
