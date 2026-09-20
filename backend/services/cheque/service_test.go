package cheque

import (
	"context"
	"crypto/rand"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/oklog/ulid/v2"
	"github.com/stellar/go-stellar-sdk/keypair"
	"github.com/stellar/go-stellar-sdk/strkey"
	"github.com/stellar/go-stellar-sdk/xdr"

	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/ports"
	"github.com/local-payment/backend/ports/portstest"
)

// ---- test fixtures --------------------------------------------------------
//
// Addresses/contract IDs must be checksum-valid strkeys (stellarx.
// IsValidAccountAddress and ScAddress both verify this), so these are
// generated once at package init rather than hand-typed — a hand-typed
// "GAAAA...` would fail the very first validation CreateCheque runs.

var (
	testSender      = mustRandomAccount()
	testReceiver    = mustRandomAccount()
	testAssetIssuer = mustRandomAccount()
	testEscrowID    = mustRandomContract()
	testTokenID     = mustRandomContract()
)

const (
	testAssetCode  = "USDC"
	testDecimals   = 7
	testPassphrase = "Test SDF Network ; September 2015"
)

func mustRandomAccount() string {
	kp, err := keypair.Random()
	if err != nil {
		panic(err)
	}
	return kp.Address()
}

func mustRandomContract() string {
	payload := make([]byte, 32)
	if _, err := rand.Read(payload); err != nil {
		panic(err)
	}
	s, err := strkey.Encode(strkey.VersionByteContract, payload)
	if err != nil {
		panic(err)
	}
	return s
}

func testConfig() Config {
	return Config{
		EscrowContractID:  testEscrowID,
		TokenContractID:   testTokenID,
		AssetCode:         testAssetCode,
		AssetIssuer:       testAssetIssuer,
		Decimals:          testDecimals,
		NetworkPassphrase: testPassphrase,
	}
}

// emptySorobanData is a valid (zero-value) base64-encoded
// xdr.SorobanTransactionData — enough for AssembleInvocation's simulate
// round-trip to decode successfully in tests that don't care about the
// resource footprint's actual contents.
func emptySorobanData(t *testing.T) string {
	t.Helper()
	s, err := xdr.MarshalBase64(xdr.SorobanTransactionData{})
	if err != nil {
		t.Fatalf("marshal empty soroban data: %v", err)
	}
	return s
}

func fundedChain(t *testing.T, sequence int64) *portstest.FakeChain {
	simData := emptySorobanData(t)
	return &portstest.FakeChain{
		GetAccountFunc: func(ctx context.Context, address string) (ports.AccountInfo, error) {
			return ports.AccountInfo{
				Address:  address,
				Sequence: sequence,
				Exists:   true,
				Balances: []ports.Balance{{AssetCode: testAssetCode, AssetIssuer: testAssetIssuer, Balance: "1000.0000000"}},
			}, nil
		},
		GetTrustlineFunc: func(ctx context.Context, address, code, issuer string) (ports.TrustlineInfo, error) {
			return ports.TrustlineInfo{Exists: true}, nil
		},
		GetLedgerFunc: func(ctx context.Context) (ports.LedgerInfo, error) {
			return ports.LedgerInfo{Sequence: 1000, CloseTime: time.Now().Unix()}, nil
		},
		SimulateTransactionFunc: func(ctx context.Context, unsignedXDR string) (ports.SimulateResult, error) {
			return ports.SimulateResult{Success: true, TransactionDataXDR: simData}, nil
		},
	}
}

func newULID() string { return ulid.Make().String() }

// ---- CreateCheque ----------------------------------------------------------

func TestCreateCheque_Validations(t *testing.T) {
	tests := []struct {
		name     string
		sender   string
		receiver string
		amount   string
		chain    func(t *testing.T) *portstest.FakeChain
		wantErr  error
	}{
		{
			name: "self transfer rejected", sender: testSender, receiver: testSender, amount: "10",
			chain: func(t *testing.T) *portstest.FakeChain { return fundedChain(t, 1) }, wantErr: errSelfTransfer,
		},
		{
			name: "invalid receiver address", sender: testSender, receiver: "not-an-address", amount: "10",
			chain: func(t *testing.T) *portstest.FakeChain { return fundedChain(t, 1) }, wantErr: errInvalidReceiver,
		},
		{
			name: "zero amount rejected", sender: testSender, receiver: testReceiver, amount: "0",
			chain: func(t *testing.T) *portstest.FakeChain { return fundedChain(t, 1) }, wantErr: errInvalidAmount,
		},
		{
			name: "negative amount rejected", sender: testSender, receiver: testReceiver, amount: "-5",
			chain: func(t *testing.T) *portstest.FakeChain { return fundedChain(t, 1) }, wantErr: errInvalidAmount,
		},
		{
			name: "non-numeric amount rejected", sender: testSender, receiver: testReceiver, amount: "abc",
			chain: func(t *testing.T) *portstest.FakeChain { return fundedChain(t, 1) }, wantErr: errInvalidAmount,
		},
		{
			name: "receiver has no trustline", sender: testSender, receiver: testReceiver, amount: "10",
			chain: func(t *testing.T) *portstest.FakeChain {
				c := fundedChain(t, 1)
				c.GetTrustlineFunc = func(ctx context.Context, address, code, issuer string) (ports.TrustlineInfo, error) {
					return ports.TrustlineInfo{Exists: false}, nil
				}
				return c
			},
			wantErr: errReceiverNoTrustline,
		},
		{
			name: "insufficient sender balance", sender: testSender, receiver: testReceiver, amount: "10",
			chain: func(t *testing.T) *portstest.FakeChain {
				c := fundedChain(t, 1)
				c.GetAccountFunc = func(ctx context.Context, address string) (ports.AccountInfo, error) {
					return ports.AccountInfo{Address: address, Sequence: 1, Exists: true, Balances: []ports.Balance{
						{AssetCode: testAssetCode, AssetIssuer: testAssetIssuer, Balance: "1.0000000"},
					}}, nil
				}
				return c
			},
			wantErr: errInsufficientBalance,
		},
		{
			name: "chain unavailable on trustline lookup", sender: testSender, receiver: testReceiver, amount: "10",
			chain: func(t *testing.T) *portstest.FakeChain {
				c := fundedChain(t, 1)
				c.GetTrustlineFunc = func(ctx context.Context, address, code, issuer string) (ports.TrustlineInfo, error) {
					return ports.TrustlineInfo{}, errors.New("rpc down")
				}
				return c
			},
			wantErr: errChainUnavailable,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			svc := newServiceWithRepo(testConfig(), newFakeRepo(), tc.chain(t))
			_, err := svc.CreateCheque(context.Background(), tc.sender, tc.receiver, tc.amount, "")
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("got err %v, want %v", err, tc.wantErr)
			}
		})
	}
}

func TestCreateCheque_AlreadyActive(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	ctx := context.Background()

	if _, err := svc.CreateCheque(ctx, testSender, testReceiver, "10", ""); err != nil {
		t.Fatalf("first CreateCheque: %v", err)
	}
	_, err := svc.CreateCheque(ctx, testSender, testReceiver, "5", "")
	if !errors.Is(err, errAlreadyActive) {
		t.Fatalf("got %v, want errAlreadyActive", err)
	}
}

func TestCreateCheque_HappyPath(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	before := time.Now()

	result, err := svc.CreateCheque(context.Background(), testSender, testReceiver, "10.5", "")
	if err != nil {
		t.Fatalf("CreateCheque: %v", err)
	}
	if _, err := ulid.ParseStrict(result.ChequeID); err != nil {
		t.Errorf("ChequeID %q is not a valid ULID: %v", result.ChequeID, err)
	}
	if result.LockXDR == "" {
		t.Error("LockXDR is empty")
	}
	if result.PreauthEntryXDR == "" {
		t.Error("PreauthEntryXDR is empty")
	}
	if result.PreauthPayloadHash == "" {
		t.Error("PreauthPayloadHash is empty")
	}
	wantExpiry := before.Add(chequeValidity)
	if diff := result.ExpiresAt.Sub(wantExpiry); diff < -time.Minute || diff > time.Minute {
		t.Errorf("ExpiresAt %v not within a minute of expected %v", result.ExpiresAt, wantExpiry)
	}

	stored, err := repo.GetCheque(context.Background(), result.ChequeID)
	if err != nil {
		t.Fatalf("GetCheque: %v", err)
	}
	if stored.State != StateImzaliRezerve {
		t.Errorf("stored state = %v, want IMZALI_REZERVE", stored.State)
	}
	if stored.AmountRaw != "105000000" {
		t.Errorf("stored AmountRaw = %q, want 105000000 (10.5 * 10^7)", stored.AmountRaw)
	}

	if len(repo.auditLog) != 1 || repo.auditLog[0].action != "cheque.lock_xdr_issued" {
		t.Errorf("audit log = %+v, want one cheque.lock_xdr_issued entry (SERVICE.md #11)", repo.auditLog)
	}
}

// ---- caller/party guards ---------------------------------------------------

func seedCheque(t *testing.T, repo *fakeRepo, state State) Cheque {
	t.Helper()
	id := newULID()
	c := Cheque{
		ID: id, SenderAddress: testSender, ReceiverAddress: testReceiver,
		TokenContract: testTokenID, AmountRaw: "100000000", Decimals: testDecimals,
		State: StateImzaliRezerve, ExpiresAt: time.Now().Add(chequeValidity),
	}
	if err := repo.CreateReservedCheque(context.Background(), c); err != nil {
		t.Fatalf("seed CreateReservedCheque: %v", err)
	}
	if state != StateImzaliRezerve {
		if err := repo.Transition(context.Background(), id, StateImzaliRezerve, state, "test_seed", ""); err != nil {
			t.Fatalf("seed Transition to %v: %v", state, err)
		}
	}
	c.State = state
	return c
}

func TestConfirmLock_WrongCallerNotFound(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateImzaliRezerve)
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

	err := svc.ConfirmLock(context.Background(), c.ID, "someone-else", "hash")
	if !errors.Is(err, errNotFound) {
		t.Fatalf("got %v, want errNotFound", err)
	}
}

func TestConfirmLock_Idempotent(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateImzaliRezerve)
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	ctx := context.Background()

	if err := svc.ConfirmLock(ctx, c.ID, testSender, "hash1"); err != nil {
		t.Fatalf("first ConfirmLock: %v", err)
	}
	// D3: a replayed confirm must be a no-op success, not an error.
	if err := svc.ConfirmLock(ctx, c.ID, testSender, "hash1"); err != nil {
		t.Fatalf("replayed ConfirmLock: %v", err)
	}
}

func TestConfirmClaim_WrongCallerNotFound(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateHavuzda)
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

	err := svc.ConfirmClaim(context.Background(), c.ID, testSender /* sender, not receiver */, "hash")
	if !errors.Is(err, errNotFound) {
		t.Fatalf("got %v, want errNotFound", err)
	}
}

func TestAcknowledgeReceipt_WrongCallerNotFound(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateTalepEdildi)
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

	err := svc.AcknowledgeReceipt(context.Background(), c.ID, testSender)
	if !errors.Is(err, errNotFound) {
		t.Fatalf("got %v, want errNotFound", err)
	}
}

func TestAcknowledgeReceipt_ReachesKapandi(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateTalepEdildi)
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

	if err := svc.AcknowledgeReceipt(context.Background(), c.ID, testReceiver); err != nil {
		t.Fatalf("AcknowledgeReceipt: %v", err)
	}
	stored, err := repo.GetCheque(context.Background(), c.ID)
	if err != nil {
		t.Fatalf("GetCheque: %v", err)
	}
	if stored.State != StateKapandi {
		t.Errorf("state = %v, want KAPANDI", stored.State)
	}
}

func TestConfirmForceCollect_WrongCallerNotFound(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateZorlaTahsilDenendi)
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

	err := svc.ConfirmForceCollect(context.Background(), c.ID, testSender, "hash", true)
	if !errors.Is(err, errNotFound) {
		t.Fatalf("got %v, want errNotFound", err)
	}
}

func TestConfirmForceCollect_CollectedVsBounced(t *testing.T) {
	for _, tc := range []struct {
		name      string
		collected bool
		want      State
	}{
		{"collected closes the cheque", true, StateKapandi},
		{"bounced marks karsiliksiz", false, StateKarsiliksiz},
	} {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeRepo()
			c := seedCheque(t, repo, StateZorlaTahsilDenendi)
			svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

			if err := svc.ConfirmForceCollect(context.Background(), c.ID, testReceiver, "hash", tc.collected); err != nil {
				t.Fatalf("ConfirmForceCollect: %v", err)
			}
			stored, err := repo.GetCheque(context.Background(), c.ID)
			if err != nil {
				t.Fatalf("GetCheque: %v", err)
			}
			if stored.State != tc.want {
				t.Errorf("state = %v, want %v", stored.State, tc.want)
			}
			if len(repo.auditLog) != 1 || repo.auditLog[0].action != "cheque.force_collect_confirmed" {
				t.Errorf("audit log = %+v, want one cheque.force_collect_confirmed entry", repo.auditLog)
			}
		})
	}
}

// ---- ClaimXDR ---------------------------------------------------------------

func TestClaimXDR(t *testing.T) {
	tests := []struct {
		name    string
		state   State
		expired bool
		caller  string
		wantErr error
	}{
		{"wrong receiver rejected", StateHavuzda, false, testSender, errInvalidReceiver},
		{"wrong state rejected", StateImzaliRezerve, false, testReceiver, errTerminalState},
		{"expired rejected", StateHavuzda, true, testReceiver, errExpired},
		{"happy path", StateHavuzda, false, testReceiver, nil},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeRepo()
			c := seedCheque(t, repo, tc.state)
			if tc.expired {
				stored, _ := repo.GetCheque(context.Background(), c.ID)
				stored.ExpiresAt = time.Now().Add(-time.Hour)
				repo.cheques[c.ID] = stored
			}
			svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

			xdrStr, err := svc.ClaimXDR(context.Background(), c.ID, tc.caller)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("got err %v, want %v", err, tc.wantErr)
			}
			if tc.wantErr == nil && xdrStr == "" {
				t.Error("expected a non-empty claim XDR on the happy path")
			}
		})
	}
}

// ---- ForceCollectXDR ---------------------------------------------------------

func TestForceCollectXDR_NoPreauthStored(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateImzaliRezerve)
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

	_, err := svc.ForceCollectXDR(context.Background(), c.ID, testReceiver)
	if !errors.Is(err, errBadRequest) {
		t.Fatalf("got %v, want errBadRequest", err)
	}
}

func TestForceCollectXDR_WrongReceiverRejected(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateImzaliRezerve)
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

	_, err := svc.ForceCollectXDR(context.Background(), c.ID, testSender)
	if !errors.Is(err, errInvalidReceiver) {
		t.Fatalf("got %v, want errInvalidReceiver", err)
	}
}

func TestForceCollectXDR_TerminalStateRejected(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateKapandi)
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

	_, err := svc.ForceCollectXDR(context.Background(), c.ID, testReceiver)
	if !errors.Is(err, errTerminalState) {
		t.Fatalf("got %v, want errTerminalState", err)
	}
}

// ---- Pool: deposit / withdraw XDR + confirm --------------------------------

func TestPoolDepositXDR_InvalidAmount(t *testing.T) {
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), fundedChain(t, 1))
	if _, err := svc.PoolDepositXDR(context.Background(), testSender, "0"); !errors.Is(err, errInvalidAmount) {
		t.Fatalf("got %v, want errInvalidAmount", err)
	}
}

// TestPoolDepositXDR_UnfundedAccountRejected and its withdraw counterpart
// below are regression tests for the "Submitting to Stellar failed" bug
// (SERVICE.md, TrustlineXDR's sibling issue): a brand-new wallet has no
// on-chain account (GetAccount returns Exists:false, Sequence:0, no error),
// and building a deposit/withdraw invocation with Sequence 0 against a
// nonexistent source is a doomed transaction Horizon can only reject with a
// result code the client doesn't recognize.
func TestPoolDepositXDR_UnfundedAccountRejected(t *testing.T) {
	chain := &portstest.FakeChain{
		GetAccountFunc: func(ctx context.Context, address string) (ports.AccountInfo, error) {
			return ports.AccountInfo{Address: address, Exists: false}, nil
		},
	}
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), chain)
	if _, err := svc.PoolDepositXDR(context.Background(), testSender, "10"); !errors.Is(err, errAccountNotFunded) {
		t.Fatalf("got %v, want errAccountNotFunded", err)
	}
}

func TestPoolWithdrawXDR_UnfundedAccountRejected(t *testing.T) {
	repo := newFakeRepo()
	if err := repo.RecordDeposit(context.Background(), testSender, "100000000", testDecimals, 1); err != nil {
		t.Fatalf("RecordDeposit: %v", err)
	}
	p := repo.pools[testSender]
	p.LastDepositAt = time.Now().Add(-8 * 24 * time.Hour) // past the lock window
	repo.pools[testSender] = p

	chain := &portstest.FakeChain{
		GetAccountFunc: func(ctx context.Context, address string) (ports.AccountInfo, error) {
			return ports.AccountInfo{Address: address, Exists: false}, nil
		},
	}
	svc := newServiceWithRepo(testConfig(), repo, chain)
	if _, err := svc.PoolWithdrawXDR(context.Background(), testSender, "10"); !errors.Is(err, errAccountNotFunded) {
		t.Fatalf("got %v, want errAccountNotFunded", err)
	}
}

func TestPoolWithdrawXDR_LockedThenUnlocked(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	ctx := context.Background()

	if err := repo.RecordDeposit(ctx, testSender, "100000000", testDecimals, 1); err != nil {
		t.Fatalf("RecordDeposit: %v", err)
	}

	// Still within the 1-week lock.
	if _, err := svc.PoolWithdrawXDR(ctx, testSender, "10"); !errors.Is(err, errPoolWithdrawLocked) {
		t.Fatalf("got %v, want errPoolWithdrawLocked", err)
	}

	// Move the deposit's clock back past the lock window.
	p := repo.pools[testSender]
	p.LastDepositAt = time.Now().Add(-8 * 24 * time.Hour)
	repo.pools[testSender] = p

	if _, err := svc.PoolWithdrawXDR(ctx, testSender, "10"); err != nil {
		t.Fatalf("expected unlocked withdraw to succeed, got %v", err)
	}
}

func TestPoolWithdrawXDR_ZeroLastDepositAtSkipsPreCheck(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	ctx := context.Background()

	// A pool row exists but predates migration 000002 (LastDepositAt is the
	// zero time) — the fast pre-check must be skipped entirely, deferring to
	// the contract's own enforcement.
	repo.pools[testSender] = PoolDeposit{OwnerAddress: testSender, AmountRaw: "100000000", Decimals: testDecimals}

	if _, err := svc.PoolWithdrawXDR(ctx, testSender, "10"); err != nil {
		t.Fatalf("expected pre-check to be skipped, got %v", err)
	}
}

// TestConfirmPoolDeposit_ParsesDecimalAmount is Fix 1's regression test: the
// amount confirmed here MUST go through money.ParseAmount and be scaled by
// decimals before it reaches the repo, exactly like PoolDepositXDR's own
// amount handling — a raw "10.5" landing in the NUMERIC(40,0) column
// unscaled would silently corrupt every /sync pool balance.
func TestConfirmPoolDeposit_ParsesDecimalAmount(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

	if err := svc.ConfirmPoolDeposit(context.Background(), testSender, "10.5", 42); err != nil {
		t.Fatalf("ConfirmPoolDeposit: %v", err)
	}
	pool, ok, err := repo.GetPool(context.Background(), testSender)
	if err != nil || !ok {
		t.Fatalf("GetPool: ok=%v err=%v", ok, err)
	}
	if pool.AmountRaw != "105000000" {
		t.Fatalf("repo AmountRaw = %q, want %q (10.5 scaled by 10^7)", pool.AmountRaw, "105000000")
	}
}

func TestConfirmPoolDeposit_RejectsInvalidAmount(t *testing.T) {
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), fundedChain(t, 1))
	for _, amt := range []string{"0", "-1", "not-a-number", "1e10"} {
		if err := svc.ConfirmPoolDeposit(context.Background(), testSender, amt, 1); !errors.Is(err, errInvalidAmount) {
			t.Errorf("amount %q: got %v, want errInvalidAmount", amt, err)
		}
	}
}

// TestConfirmPoolWithdraw_ParsesDecimalAmount is Fix 1's withdraw-side twin.
func TestConfirmPoolWithdraw_ParsesDecimalAmount(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	ctx := context.Background()

	if err := repo.RecordDeposit(ctx, testSender, "200000000", testDecimals, 1); err != nil {
		t.Fatalf("seed RecordDeposit: %v", err)
	}
	if err := svc.ConfirmPoolWithdraw(ctx, testSender, "10.5"); err != nil {
		t.Fatalf("ConfirmPoolWithdraw: %v", err)
	}
	pool, _, err := repo.GetPool(ctx, testSender)
	if err != nil {
		t.Fatalf("GetPool: %v", err)
	}
	if pool.AmountRaw != "95000000" {
		t.Fatalf("repo AmountRaw = %q, want %q (200000000 - 105000000)", pool.AmountRaw, "95000000")
	}
}

// ---- Sync / ExpiredFundedCheques / MarkRefunded ----------------------------

func TestSync_ReturnsActiveChequesAndPool(t *testing.T) {
	repo := newFakeRepo()
	seedCheque(t, repo, StateHavuzda)
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

	view, err := svc.Sync(context.Background(), testReceiver)
	if err != nil {
		t.Fatalf("Sync: %v", err)
	}
	if len(view.Cheques) != 1 {
		t.Fatalf("got %d cheques, want 1", len(view.Cheques))
	}
	if !view.TrustlineReady {
		t.Error("TrustlineReady = false, want true")
	}
	// SERVICE.md #20 regression: the client learns the network to sign
	// against from /sync, so this must be the backend's real config value,
	// never empty or a client-guessed default.
	if view.NetworkPassphrase != testPassphrase {
		t.Errorf("NetworkPassphrase = %q, want %q", view.NetworkPassphrase, testPassphrase)
	}
}

func TestExpiredFundedCheques_And_MarkRefunded(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateHavuzda)
	stored, _ := repo.GetCheque(context.Background(), c.ID)
	stored.ExpiresAt = time.Now().Add(-time.Minute)
	repo.cheques[c.ID] = stored

	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	ctx := context.Background()

	expired, err := svc.ExpiredFundedCheques(ctx)
	if err != nil {
		t.Fatalf("ExpiredFundedCheques: %v", err)
	}
	if len(expired) != 1 {
		t.Fatalf("got %d expired cheques, want 1", len(expired))
	}

	if err := svc.MarkRefunded(ctx, c.ID, "refund-hash"); err != nil {
		t.Fatalf("MarkRefunded: %v", err)
	}
	final, err := repo.GetCheque(ctx, c.ID)
	if err != nil {
		t.Fatalf("GetCheque: %v", err)
	}
	if final.State != StateIadeEdildi {
		t.Errorf("state = %v, want IADE_EDILDI", final.State)
	}
}

// ---- DB-not-ready propagation ----------------------------------------------

// TestService_DBNotReady exercises the production NewService constructor
// (not newServiceWithRepo) against an unconnected *dbx.Pool — the brief
// post-boot window RequireReady normally intercepts at the HTTP layer, but
// Service must still fail cleanly, not nil-pointer-panic, if reached first.
func TestService_DBNotReady(t *testing.T) {
	pool := &dbx.Pool{} // never connected: Get() returns nil
	svc := NewService(testConfig(), pool, fundedChain(t, 1))

	_, err := svc.CreateCheque(context.Background(), testSender, testReceiver, "10", "")
	if !errors.Is(err, ErrDBNotReadyErr) {
		t.Fatalf("got %v, want ErrDBNotReadyErr", err)
	}
}

// ---- tap/scan payment requests (requestId) ---------------------------------

func TestCreateCheque_StoresRequestID(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))

	result, err := svc.CreateCheque(context.Background(), testSender, testReceiver, "10", "req-abc-123")
	if err != nil {
		t.Fatalf("CreateCheque: %v", err)
	}
	if got := repo.cheques[result.ChequeID].RequestID; got != "req-abc-123" {
		t.Errorf("stored RequestID = %q, want req-abc-123", got)
	}
}

func TestCreateCheque_RequestUsedByAnotherSender(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	ctx := context.Background()
	otherSender := mustRandomAccount()

	if _, err := svc.CreateCheque(ctx, testSender, testReceiver, "10", "req-1"); err != nil {
		t.Fatalf("first CreateCheque: %v", err)
	}
	// A different sender has no active cheque, so only the request id can
	// be the reason this is refused.
	_, err := svc.CreateCheque(ctx, otherSender, testReceiver, "10", "req-1")
	if !errors.Is(err, errRequestUsed) {
		t.Fatalf("got %v, want errRequestUsed", err)
	}
}

func TestCreateCheque_SameRequestIDForADifferentReceiverIsAnotherRequest(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	ctx := context.Background()

	if _, err := svc.CreateCheque(ctx, testSender, testReceiver, "10", "req-1"); err != nil {
		t.Fatalf("first CreateCheque: %v", err)
	}
	if _, err := svc.CreateCheque(ctx, mustRandomAccount(), mustRandomAccount(), "10", "req-1"); err != nil {
		t.Fatalf("same id, other receiver should be allowed: %v", err)
	}
}

func TestCreateCheque_NoRequestIDIsUnrestricted(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	ctx := context.Background()

	for i := 0; i < 2; i++ {
		if _, err := svc.CreateCheque(ctx, mustRandomAccount(), testReceiver, "10", ""); err != nil {
			t.Fatalf("plain cheque #%d: %v", i, err)
		}
	}
}

func TestCreateCheque_InvalidRequestIDRejectedBeforeAnyChainCall(t *testing.T) {
	for _, bad := range []string{"has space", "a/b", "semi;colon", strings.Repeat("a", 65), "ünicode"} {
		t.Run(bad, func(t *testing.T) {
			chain := &portstest.FakeChain{} // any chain call would panic on a nil func
			svc := newServiceWithRepo(testConfig(), newFakeRepo(), chain)
			_, err := svc.CreateCheque(context.Background(), testSender, testReceiver, "10", bad)
			if !errors.Is(err, errInvalidRequestID) {
				t.Fatalf("got %v, want errInvalidRequestID", err)
			}
		})
	}
}

func TestCreateCheque_RequestIDBoundaryLength(t *testing.T) {
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), fundedChain(t, 1))
	if _, err := svc.CreateCheque(context.Background(), testSender, testReceiver, "10", strings.Repeat("a", 64)); err != nil {
		t.Fatalf("64-char id should be accepted: %v", err)
	}
}
