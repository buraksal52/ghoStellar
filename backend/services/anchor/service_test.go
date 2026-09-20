package anchor

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
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

// TestTrustlineXDR_UnfundedAccountRejected is the regression test for the
// "Submitting to Stellar failed" bug: a brand-new wallet has no on-chain
// account (GetAccount returns Exists:false, Sequence:0, no error) — before
// this check, TrustlineXDR built a change_trust tx with Sequence 0 against
// a nonexistent source and let it go all the way to a signed submission
// Horizon could only reject with a result code the client didn't recognize.
func TestTrustlineXDR_UnfundedAccountRejected(t *testing.T) {
	chain := &portstest.FakeChain{
		GetAccountFunc: func(ctx context.Context, address string) (ports.AccountInfo, error) {
			return ports.AccountInfo{Address: address, Exists: false}, nil
		},
	}
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), NewClient(http.DefaultClient), chain, discardLogger())

	_, err := svc.TrustlineXDR(context.Background(), "GADDR")
	if !errors.Is(err, errAccountNotFunded) {
		t.Fatalf("got %v, want errAccountNotFunded", err)
	}
}

func withdrawTestService(t *testing.T) (*Service, Config, string) {
	t.Helper()
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
	return newServiceWithRepo(cfg, newFakeRepo(), NewClient(http.DefaultClient), chain, discardLogger()), cfg, sender.Address()
}

func TestWithdrawPaymentXDR_BuildsPaymentWithMemo(t *testing.T) {
	svc, cfg, owner := withdrawTestService(t)
	treasury := testIssuer(t)

	xdrStr, err := svc.WithdrawPaymentXDR(context.Background(), owner, treasury, "id", "12345", "5")
	if err != nil {
		t.Fatalf("WithdrawPaymentXDR: %v", err)
	}
	genericTx, err := txnbuild.TransactionFromXDR(xdrStr)
	if err != nil {
		t.Fatalf("decode payment XDR: %v", err)
	}
	tx, ok := genericTx.Transaction()
	if !ok {
		t.Fatal("expected a simple transaction")
	}
	if tx.SourceAccount().AccountID != owner {
		t.Errorf("source account = %q, want %q", tx.SourceAccount().AccountID, owner)
	}
	if got, ok := tx.Memo().(txnbuild.MemoID); !ok || uint64(got) != 12345 {
		t.Errorf("memo = %#v, want MemoID(12345)", tx.Memo())
	}
	ops := tx.Operations()
	if len(ops) != 1 {
		t.Fatalf("got %d operations, want 1", len(ops))
	}
	pay, ok := ops[0].(*txnbuild.Payment)
	if !ok {
		t.Fatalf("operation is %T, want *txnbuild.Payment", ops[0])
	}
	if pay.Destination != treasury {
		t.Errorf("destination = %q, want %q", pay.Destination, treasury)
	}
	if pay.Amount != "5.0000000" {
		t.Errorf("amount = %q, want 5.0000000", pay.Amount)
	}
	if code, issuer := pay.Asset.GetCode(), pay.Asset.GetIssuer(); code != cfg.AssetCode || issuer != cfg.AssetIssuer {
		t.Errorf("asset = %s/%s, want %s/%s", code, issuer, cfg.AssetCode, cfg.AssetIssuer)
	}
}

func TestWithdrawPaymentXDR_TextAndNoMemo(t *testing.T) {
	svc, _, owner := withdrawTestService(t)
	treasury := testIssuer(t)

	for _, tc := range []struct{ name, memoType, memo string }{
		{"text", "text", "ref-42"},
		{"none", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := svc.WithdrawPaymentXDR(context.Background(), owner, treasury, tc.memoType, tc.memo, "1.5"); err != nil {
				t.Fatalf("WithdrawPaymentXDR: %v", err)
			}
		})
	}
}

func TestWithdrawPaymentXDR_RejectsBadInput(t *testing.T) {
	svc, _, owner := withdrawTestService(t)
	treasury := testIssuer(t)

	for _, tc := range []struct{ name, dest, memoType, memo, amount string }{
		{"bad destination", "not-an-address", "id", "1", "5"},
		{"contract destination", "CDD7FWHQIAF2Z57CMZUO5BT4TY4VTIZKXLYD4WKQ7HDLO5IQOYU6V3ID", "id", "1", "5"},
		{"zero amount", treasury, "id", "1", "0"},
		{"negative amount", treasury, "id", "1", "-1"},
		{"too many decimals", treasury, "id", "1", "1.00000001"},
		{"scientific notation", treasury, "id", "1", "1e3"},
		{"non-numeric id memo", treasury, "id", "abc", "5"},
		{"oversized text memo", treasury, "text", "this memo is far longer than 28 bytes", "5"},
		{"unknown memo type", treasury, "hash", "abcd", "5"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := svc.WithdrawPaymentXDR(context.Background(), owner, tc.dest, tc.memoType, tc.memo, tc.amount)
			if !errors.Is(err, errBadRequest) {
				t.Fatalf("got %v, want errBadRequest", err)
			}
		})
	}
}

func TestWithdrawPaymentXDR_NativeAssetUsesNativePayment(t *testing.T) {
	svc, _, owner := withdrawTestService(t)
	svc.cfg.AssetCode = "native"
	svc.cfg.AssetIssuer = ""
	xdrStr, err := svc.WithdrawPaymentXDR(context.Background(), owner, testIssuer(t), "id", "1", "5")
	if err != nil {
		t.Fatalf("WithdrawPaymentXDR: %v", err)
	}
	genericTx, err := txnbuild.TransactionFromXDR(xdrStr)
	if err != nil {
		t.Fatalf("decode xdr: %v", err)
	}
	tx, ok := genericTx.Transaction()
	if !ok {
		t.Fatal("expected a simple transaction")
	}
	pay, ok := tx.Operations()[0].(*txnbuild.Payment)
	if !ok || !pay.Asset.IsNative() {
		t.Fatalf("payment asset = %#v, want native XLM", tx.Operations()[0])
	}
}

func TestWithdrawPaymentXDR_UnfundedAccountRejected(t *testing.T) {
	chain := &portstest.FakeChain{
		GetAccountFunc: func(ctx context.Context, address string) (ports.AccountInfo, error) {
			return ports.AccountInfo{Address: address, Exists: false}, nil
		},
	}
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), NewClient(http.DefaultClient), chain, discardLogger())

	_, err := svc.WithdrawPaymentXDR(context.Background(), "GOWNER", testIssuer(t), "id", "1", "5")
	if !errors.Is(err, errAccountNotFunded) {
		t.Fatalf("got %v, want errAccountNotFunded", err)
	}
}

// TestStartInteractive_NoSEP24ServerFailsReadably pins the fix for the app
// calling a SEP-24 path the TR mock anchor never published: the failure must
// name the missing endpoint, not surface requireHTTPS on a schemeless URL.
func TestStartInteractive_NoSEP24ServerFailsReadably(t *testing.T) {
	client := tomlServer(t, `SIGNING_KEY="GSIGNINGKEY"`) // no TRANSFER_SERVER_0024
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	repo := newFakeRepo()
	repo.trustlines["GADDR/"+cfg.AssetCode+"/"+cfg.AssetIssuer] = "active"
	svc := newServiceWithRepo(cfg, repo, client, &portstest.FakeChain{}, discardLogger())

	_, _, err := svc.StartDeposit(context.Background(), testAnchorID, "anchor-jwt", "GADDR")
	if err == nil || !strings.Contains(err.Error(), "no SEP-24 transfer server") {
		t.Fatalf("got %v, want an error naming the missing SEP-24 server", err)
	}
}

func TestConfirmTrustline_OnChainRecordsActiveWithChainLedger(t *testing.T) {
	repo := newFakeRepo()
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	chain := &portstest.FakeChain{
		GetTrustlineFunc: func(ctx context.Context, address, assetCode, assetIssuer string) (ports.TrustlineInfo, error) {
			return ports.TrustlineInfo{Exists: true}, nil
		},
		GetLedgerFunc: func(ctx context.Context) (ports.LedgerInfo, error) {
			return ports.LedgerInfo{Sequence: 4242}, nil
		},
	}
	svc := newServiceWithRepo(cfg, repo, NewClient(http.DefaultClient), chain, discardLogger())

	if err := svc.ConfirmTrustline(context.Background(), "GADDR"); err != nil {
		t.Fatalf("ConfirmTrustline: %v", err)
	}
	key := "GADDR/" + cfg.AssetCode + "/" + cfg.AssetIssuer
	if got := repo.trustlines[key]; got != "active" {
		t.Errorf("trustline state = %q, want active", got)
	}
	if got := repo.trustlineSeq[key]; got != 4242 {
		t.Errorf("ledger_seq = %d, want the chain's 4242", got)
	}
}

// TestConfirmTrustline_NotOnChainIsNotActive is the regression test for
// "setup says completed but isn't": the client's word is not enough — a
// trustline the chain doesn't have must never be recorded active, and a row
// wrongly left active by an earlier unverified confirm is repaired.
func TestConfirmTrustline_NotOnChainIsNotActive(t *testing.T) {
	repo := newFakeRepo()
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	key := "GADDR/" + cfg.AssetCode + "/" + cfg.AssetIssuer
	repo.trustlines[key] = "active" // stale, wrong row from the old behaviour
	chain := &portstest.FakeChain{
		GetTrustlineFunc: func(ctx context.Context, address, assetCode, assetIssuer string) (ports.TrustlineInfo, error) {
			return ports.TrustlineInfo{Exists: false}, nil
		},
	}
	svc := newServiceWithRepo(cfg, repo, NewClient(http.DefaultClient), chain, discardLogger())

	err := svc.ConfirmTrustline(context.Background(), "GADDR")
	if !errors.Is(err, errTrustlineMissing) {
		t.Fatalf("got %v, want errTrustlineMissing", err)
	}
	if got := repo.trustlines[key]; got != "missing" {
		t.Errorf("trustline state = %q, want missing", got)
	}
	if chain.GetLedgerCalls != 0 {
		t.Error("the ledger must not be read when there is no trustline")
	}
}

func TestConfirmTrustline_ChainErrorLeavesRowUntouched(t *testing.T) {
	repo := newFakeRepo()
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	chain := &portstest.FakeChain{
		GetTrustlineFunc: func(ctx context.Context, address, assetCode, assetIssuer string) (ports.TrustlineInfo, error) {
			return ports.TrustlineInfo{}, errors.New("horizon down")
		},
	}
	svc := newServiceWithRepo(cfg, repo, NewClient(http.DefaultClient), chain, discardLogger())

	err := svc.ConfirmTrustline(context.Background(), "GADDR")
	if !errors.Is(err, errChainUnavailable) {
		t.Fatalf("got %v, want errChainUnavailable", err)
	}
	if len(repo.trustlines) != 0 {
		t.Errorf("no row should be written when the chain can't be read, got %v", repo.trustlines)
	}
}

// TestChallenge_PassesThroughAnchorNetworkPassphrase is the regression test
// for SERVICE.md #20: the anchor's own network_passphrase must reach the
// client, not be silently dropped (the client would otherwise sign the
// anchor's challenge with its own network id — a structurally valid but
// cryptographically wrong signature).
func TestChallenge_PassesThroughAnchorNetworkPassphrase(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/stellar.toml":
			w.Write([]byte(`WEB_AUTH_ENDPOINT="https://anchor.example/auth"` + "\n" + `SIGNING_KEY="GSIGNINGKEY"`))
		case "/auth":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"transaction":"unsigned-xdr","network_passphrase":"Public Global Stellar Network ; September 2015"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	client := NewClient(dialingClient(srv))
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), client, &portstest.FakeChain{}, discardLogger())

	txn, netPassphrase, err := svc.Challenge(context.Background(), testAnchorID, "GACCOUNT")
	if err != nil {
		t.Fatalf("Challenge: %v", err)
	}
	if txn != "unsigned-xdr" {
		t.Errorf("transaction = %q, want unsigned-xdr", txn)
	}
	if netPassphrase != "Public Global Stellar Network ; September 2015" {
		t.Errorf("networkPassphrase = %q, want the anchor's own", netPassphrase)
	}
}

// TestChallenge_NoAnchorPassphraseComesBackEmpty pins the fallback contract:
// SEP-10 makes network_passphrase optional, so an anchor that omits it must
// not fail the call — the caller falls back to its own network.
func TestChallenge_NoAnchorPassphraseComesBackEmpty(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/stellar.toml":
			w.Write([]byte(`WEB_AUTH_ENDPOINT="https://anchor.example/auth"` + "\n" + `SIGNING_KEY="GSIGNINGKEY"`))
		case "/auth":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"transaction":"unsigned-xdr"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	client := NewClient(dialingClient(srv))
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), client, &portstest.FakeChain{}, discardLogger())

	_, netPassphrase, err := svc.Challenge(context.Background(), testAnchorID, "GACCOUNT")
	if err != nil {
		t.Fatalf("Challenge: %v", err)
	}
	if netPassphrase != "" {
		t.Errorf("networkPassphrase = %q, want empty when the anchor omits it", netPassphrase)
	}
}

func TestReportTransaction_UnknownAnchorRejected(t *testing.T) {
	svc := newServiceWithRepo(testConfig(testAnchorDomain, testIssuer(t)), newFakeRepo(), NewClient(http.DefaultClient), &portstest.FakeChain{}, discardLogger())
	err := svc.ReportTransaction(context.Background(), "not-the-configured-anchor", "GADDR", Transaction{ID: "tx1"})
	if !errors.Is(err, errNotAllowed) {
		t.Fatalf("got %v, want errNotAllowed", err)
	}
}
