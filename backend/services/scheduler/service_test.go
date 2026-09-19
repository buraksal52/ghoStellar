package scheduler

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stellar/go-stellar-sdk/keypair"
	"github.com/stellar/go-stellar-sdk/strkey"
	"github.com/stellar/go-stellar-sdk/xdr"

	"github.com/local-payment/backend/ports"
	"github.com/local-payment/backend/ports/portstest"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(discardWriter{}, nil))
}

type discardWriter struct{}

func (discardWriter) Write(p []byte) (int, error) { return len(p), nil }

func testConfig(t *testing.T, escrowID string) (Config, *keypair.Full) {
	t.Helper()
	keeper, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	return Config{
		EscrowContractID:  escrowID,
		NetworkPassphrase: "Test SDF Network ; September 2015",
		KeeperSeed:        keeper.Seed(),
	}, keeper
}

// testContractID returns a syntactically valid (if meaningless) "C..."
// contract strkey — enough for stellarx.InvokeContract's own validation,
// which only checks the strkey's shape (including checksum), not that a
// contract actually exists on-chain at that address.
func testContractID(t *testing.T) string {
	t.Helper()
	payload := make([]byte, 32)
	s, err := strkey.Encode(strkey.VersionByteContract, payload)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func emptySorobanDataXDR(t *testing.T) string {
	t.Helper()
	s, err := xdr.MarshalBase64(xdr.SorobanTransactionData{})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func fundedChain(t *testing.T) *portstest.FakeChain {
	simData := emptySorobanDataXDR(t)
	return &portstest.FakeChain{
		GetAccountFunc: func(ctx context.Context, address string) (ports.AccountInfo, error) {
			return ports.AccountInfo{Address: address, Sequence: 1, Exists: true}, nil
		},
		SimulateTransactionFunc: func(ctx context.Context, unsignedXDR string) (ports.SimulateResult, error) {
			return ports.SimulateResult{Success: true, TransactionDataXDR: simData}, nil
		},
		SubmitSorobanFunc: func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
			return ports.SubmitResult{Hash: "refund-hash", Successful: true}, nil
		},
	}
}

func chequeServer(t *testing.T, expired []ExpiredCheque) (*httptest.Server, *int) {
	t.Helper()
	markCalls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/internal/cheques/expired-funded":
			w.Header().Set("Content-Type", "application/json")
			body, err := json.Marshal(struct {
				Data []ExpiredCheque `json:"data"`
			}{Data: expired})
			if err != nil {
				t.Fatal(err)
			}
			w.Write(body)
		case r.Method == "POST":
			markCalls++
			w.WriteHeader(http.StatusOK)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, &markCalls
}

func TestSweepExpiredCheques_RefundsAllAndMarksThem(t *testing.T) {
	escrowID := testContractID(t)
	cfg, keeper := testConfig(t, escrowID)
	chain := fundedChain(t)

	expired := []ExpiredCheque{
		{ID: "01F00000000000000000000001", SenderAddress: keeper.Address(), ReceiverAddress: keeper.Address(), TokenContract: escrowID, AmountRaw: "100", Decimals: 7},
	}
	srv, markCalls := chequeServer(t, expired)
	client := NewChequeClient(srv.URL, "internal-key", nil)

	svc, err := NewService(cfg, chain, client, discardLogger())
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}

	svc.SweepExpiredCheques(context.Background())

	if *markCalls != 1 {
		t.Fatalf("mark-refunded called %d times, want 1", *markCalls)
	}
	if chain.SubmitSorobanCalls != 1 {
		t.Fatalf("SubmitSoroban called %d times, want 1", chain.SubmitSorobanCalls)
	}
}

func TestSweepExpiredCheques_NoneExpired_NoOp(t *testing.T) {
	escrowID := testContractID(t)
	cfg, _ := testConfig(t, escrowID)
	chain := fundedChain(t)
	srv, markCalls := chequeServer(t, nil)
	client := NewChequeClient(srv.URL, "internal-key", nil)

	svc, err := NewService(cfg, chain, client, discardLogger())
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}
	svc.SweepExpiredCheques(context.Background())

	if *markCalls != 0 {
		t.Errorf("mark-refunded called %d times, want 0", *markCalls)
	}
	if chain.SubmitSorobanCalls != 0 {
		t.Errorf("SubmitSoroban called %d times, want 0", chain.SubmitSorobanCalls)
	}
}

// TestSweepExpiredCheques_OneFailureDoesNotStopTheRest is the sweep's core
// resilience guarantee: a single cheque failing to refund (e.g. a bad ID or
// a transient RPC error) must not abort the whole sweep.
func TestSweepExpiredCheques_OneFailureDoesNotStopTheRest(t *testing.T) {
	escrowID := testContractID(t)
	cfg, keeper := testConfig(t, escrowID)
	chain := fundedChain(t)

	expired := []ExpiredCheque{
		{ID: "not-a-valid-ulid", SenderAddress: keeper.Address(), ReceiverAddress: keeper.Address(), TokenContract: escrowID, AmountRaw: "100", Decimals: 7},
		{ID: "01F00000000000000000000002", SenderAddress: keeper.Address(), ReceiverAddress: keeper.Address(), TokenContract: escrowID, AmountRaw: "100", Decimals: 7},
	}
	srv, markCalls := chequeServer(t, expired)
	client := NewChequeClient(srv.URL, "internal-key", nil)

	svc, err := NewService(cfg, chain, client, discardLogger())
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}
	svc.SweepExpiredCheques(context.Background())

	// The first (malformed ID) cheque fails at decodeULID before ever
	// touching the chain; the second must still be refunded.
	if *markCalls != 1 {
		t.Fatalf("mark-refunded called %d times, want 1 (only the valid cheque)", *markCalls)
	}
	if chain.SubmitSorobanCalls != 1 {
		t.Fatalf("SubmitSoroban called %d times, want 1", chain.SubmitSorobanCalls)
	}
}

// TestSweepExpiredCheques_FailedChequeBacksOff is SERVICE.md #15's
// regression test: a cheque that fails to refund must not be retried on
// the very next sweep tick — it should sit in backoff until its
// nextAttempt passes.
func TestSweepExpiredCheques_FailedChequeBacksOff(t *testing.T) {
	escrowID := testContractID(t)
	cfg, keeper := testConfig(t, escrowID)
	chain := fundedChain(t)
	chain.GetAccountFunc = func(ctx context.Context, address string) (ports.AccountInfo, error) {
		return ports.AccountInfo{Address: address, Exists: false}, nil // always fails refundOne
	}
	expired := []ExpiredCheque{
		{ID: "01F00000000000000000000004", SenderAddress: keeper.Address(), ReceiverAddress: keeper.Address(), TokenContract: escrowID, AmountRaw: "100", Decimals: 7},
	}
	srv, markCalls := chequeServer(t, expired)
	client := NewChequeClient(srv.URL, "internal-key", nil)
	svc, err := NewService(cfg, chain, client, discardLogger())
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}

	svc.SweepExpiredCheques(context.Background()) // 1st attempt: fails, enters backoff
	if chain.GetAccountCalls != 1 {
		t.Fatalf("GetAccount called %d times after 1st sweep, want 1", chain.GetAccountCalls)
	}

	svc.SweepExpiredCheques(context.Background()) // 2nd attempt: still within backoff window
	if chain.GetAccountCalls != 1 {
		t.Fatalf("GetAccount called %d times after 2nd sweep, want still 1 (should be in backoff)", chain.GetAccountCalls)
	}
	if *markCalls != 0 {
		t.Errorf("mark-refunded called %d times, want 0", *markCalls)
	}
}

func TestRefundOne_KeeperAccountMissing(t *testing.T) {
	escrowID := testContractID(t)
	cfg, keeper := testConfig(t, escrowID)
	chain := fundedChain(t)
	chain.GetAccountFunc = func(ctx context.Context, address string) (ports.AccountInfo, error) {
		return ports.AccountInfo{Address: address, Exists: false}, nil
	}
	srv, markCalls := chequeServer(t, nil)
	client := NewChequeClient(srv.URL, "internal-key", nil)
	svc, err := NewService(cfg, chain, client, discardLogger())
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}

	err = svc.refundOne(context.Background(), ExpiredCheque{
		ID: "01F00000000000000000000003", SenderAddress: keeper.Address(), ReceiverAddress: keeper.Address(), TokenContract: escrowID, AmountRaw: "1", Decimals: 7,
	})
	if err == nil {
		t.Fatal("expected an error when the keeper account does not exist on-chain")
	}
	if *markCalls != 0 {
		t.Errorf("mark-refunded should not be called when refund fails")
	}
}

func TestNewService_InvalidKeeperSeedRejected(t *testing.T) {
	cfg := Config{EscrowContractID: testContractID(t), NetworkPassphrase: "Test SDF Network ; September 2015", KeeperSeed: "not-a-valid-seed"}
	_, err := NewService(cfg, &portstest.FakeChain{}, NewChequeClient("http://localhost", "k", nil), discardLogger())
	if err == nil {
		t.Fatal("expected an error for an invalid keeper seed")
	}
}
