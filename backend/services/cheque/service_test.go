package cheque

import (
	"context"
	"crypto/rand"
	"errors"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/oklog/ulid/v2"
	"github.com/stellar/go-stellar-sdk/keypair"
	"github.com/stellar/go-stellar-sdk/strkey"
	"github.com/stellar/go-stellar-sdk/xdr"

	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/pkg/stellarx"
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
				Balances: []ports.Balance{
					{AssetCode: testAssetCode, AssetIssuer: testAssetIssuer, Balance: "1000.0000000"},
					// A funded Stellar account always carries a native balance;
					// well above nativeReserveHeadroomRaw so fundedChain models a
					// wallet with enough XLM to pay its own transaction fees.
					{AssetCode: "native", Balance: "100.0000000"},
				},
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

// chequeRecordResultXDR builds a get_cheque simulateTransaction ResultXDR
// the way pay-escrow's ChequeRecord is documented to encode (see
// pkg/stellarx/chequerecord_test.go's buildScMap/buildUnitEnum, duplicated
// here rather than exported — this is a cheque-package-only test need).
func chequeRecordResultXDR(t *testing.T, c Cheque, chainState string) string {
	t.Helper()
	sym := func(s string) xdr.ScVal {
		v, err := stellarx.ScSymbol(s)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	addr := func(a string) xdr.ScVal {
		v, err := stellarx.ScAddress(a)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	amount, ok := new(big.Int).SetString(c.AmountRaw, 10)
	if !ok {
		t.Fatalf("bad AmountRaw %q", c.AmountRaw)
	}
	amountSc, err := stellarx.ScI128(amount)
	if err != nil {
		t.Fatal(err)
	}
	expiresAtSc, err := stellarx.ScUint64(uint64(c.ExpiresAt.Unix()))
	if err != nil {
		t.Fatal(err)
	}
	entries := xdr.ScMap{
		{Key: sym("sender"), Val: addr(c.SenderAddress)},
		{Key: sym("receiver"), Val: addr(c.ReceiverAddress)},
		{Key: sym("token"), Val: addr(c.TokenContract)},
		{Key: sym("amount"), Val: amountSc},
		{Key: sym("expires_at"), Val: expiresAtSc},
		{Key: sym("state"), Val: sym(chainState)},
	}
	record, err := xdr.NewScVal(xdr.ScValTypeScvMap, &entries)
	if err != nil {
		t.Fatal(err)
	}
	resultXDR, err := xdr.MarshalBase64(record)
	if err != nil {
		t.Fatal(err)
	}
	return resultXDR
}

// TestClaimXDR_RepairsFromChainWhenLockConfirmWasLost is SERVICE.md #1's
// regression test for ClaimXDR: the sender's confirm-lock ("the caller's
// word") can be lost to a network blip after the lock transaction itself
// already landed on chain. A receiver must still be able to claim — not be
// stuck behind a permanent errTerminalState — once the contract's own
// get_cheque says Funded.
func TestClaimXDR_RepairsFromChainWhenLockConfirmWasLost(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateImzaliRezerve)
	chain := fundedChain(t, 1)
	chain.SimulateTransactionFunc = func(ctx context.Context, unsignedXDR string) (ports.SimulateResult, error) {
		return ports.SimulateResult{Success: true, TransactionDataXDR: emptySorobanData(t), ResultXDR: chequeRecordResultXDR(t, c, "Funded")}, nil
	}
	svc := newServiceWithRepo(testConfig(), repo, chain)

	xdrStr, err := svc.ClaimXDR(context.Background(), c.ID, testReceiver)
	if err != nil {
		t.Fatalf("ClaimXDR: %v", err)
	}
	if xdrStr == "" {
		t.Error("expected a non-empty claim XDR once the chain confirms Funded")
	}
	repaired, getErr := repo.GetCheque(context.Background(), c.ID)
	if getErr != nil {
		t.Fatalf("GetCheque: %v", getErr)
	}
	if repaired.State != StateHavuzda {
		t.Errorf("local state = %v, want %v (repaired from chain)", repaired.State, StateHavuzda)
	}
}

// TestClaimXDR_AlreadyClaimedOnChainIsNotTerminal is the counterpart: a
// receiver whose own earlier claim submitted successfully but whose
// ConfirmClaim call back to the backend then failed must see
// errAlreadyClaimed (recognizable as "you already got this"), not a
// generic errTerminalState indistinguishable from every other closed case.
func TestClaimXDR_AlreadyClaimedOnChainIsNotTerminal(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateImzaliRezerve)
	chain := fundedChain(t, 1)
	chain.SimulateTransactionFunc = func(ctx context.Context, unsignedXDR string) (ports.SimulateResult, error) {
		return ports.SimulateResult{Success: true, TransactionDataXDR: emptySorobanData(t), ResultXDR: chequeRecordResultXDR(t, c, "Claimed")}, nil
	}
	svc := newServiceWithRepo(testConfig(), repo, chain)

	_, err := svc.ClaimXDR(context.Background(), c.ID, testReceiver)
	if !errors.Is(err, errAlreadyClaimed) {
		t.Fatalf("got %v, want errAlreadyClaimed", err)
	}
	repaired, getErr := repo.GetCheque(context.Background(), c.ID)
	if getErr != nil {
		t.Fatalf("GetCheque: %v", getErr)
	}
	if repaired.State != StateTalepEdildi {
		t.Errorf("local state = %v, want %v (repaired from chain)", repaired.State, StateTalepEdildi)
	}
}

// TestClaimXDR_ChainUnreadableStaysTerminal pins today's behavior when the
// chain can't be read at all (RPC hiccup, decode failure): the existing
// errTerminalState refusal for a pre-HAVUZDA cheque, not a false repair.
func TestClaimXDR_ChainUnreadableStaysTerminal(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateImzaliRezerve)
	chain := fundedChain(t, 1)
	chain.SimulateTransactionFunc = func(ctx context.Context, unsignedXDR string) (ports.SimulateResult, error) {
		return ports.SimulateResult{}, errors.New("soroban rpc: unavailable")
	}
	svc := newServiceWithRepo(testConfig(), repo, chain)

	_, err := svc.ClaimXDR(context.Background(), c.ID, testReceiver)
	if !errors.Is(err, errTerminalState) {
		t.Fatalf("got %v, want errTerminalState", err)
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

// TestPoolDepositXDR_SimulationFailureIsItsOwnError: a funded account with no
// trustline / not enough USDC makes the contract call fail in simulation.
// That used to surface as a generic cheque.bad_request the app could only
// show as "Something went wrong"; it must stay identifiable.
func TestPoolDepositXDR_SimulationFailureIsItsOwnError(t *testing.T) {
	chain := fundedChain(t, 5)
	chain.SimulateTransactionFunc = func(ctx context.Context, unsignedXDR string) (ports.SimulateResult, error) {
		return ports.SimulateResult{Success: false, Error: "HostError: Error(Contract, #10)"}, nil
	}
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), chain)
	_, err := svc.PoolDepositXDR(context.Background(), testSender, "10")
	if !errors.Is(err, errSimulationFailed) {
		t.Fatalf("got %v, want errSimulationFailed", err)
	}
	if !strings.Contains(err.Error(), "Error(Contract, #10)") {
		t.Errorf("error %q should keep the simulator's message for the logs", err)
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

func TestPoolWithdrawXDR_ImmediatelyAfterDeposit(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	ctx := context.Background()

	if err := repo.RecordDeposit(ctx, testSender, "100000000", testDecimals, 1); err != nil {
		t.Fatalf("RecordDeposit: %v", err)
	}

	if _, err := svc.PoolWithdrawXDR(ctx, testSender, "10"); err != nil {
		t.Fatalf("expected immediate withdraw to succeed, got %v", err)
	}
}

// poolRecordResultXDR builds a get_pool simulateTransaction ResultXDR the
// way pay-escrow's PoolRecord is documented to encode (token, amount,
// last_deposit_at — see pkg/stellarx/chequerecord_test.go's
// TestDecodePoolRecord_RoundTrip and chequeRecordResultXDR above, which this
// mirrors for the pool package's own tests).
func poolRecordResultXDR(t *testing.T, token string, amountRaw *big.Int) string {
	t.Helper()
	sym := func(s string) xdr.ScVal {
		v, err := stellarx.ScSymbol(s)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	tokenSc, err := stellarx.ScAddress(token)
	if err != nil {
		t.Fatal(err)
	}
	amountSc, err := stellarx.ScI128(amountRaw)
	if err != nil {
		t.Fatal(err)
	}
	lastDepositSc, err := stellarx.ScUint64(0)
	if err != nil {
		t.Fatal(err)
	}
	entries := xdr.ScMap{
		{Key: sym("token"), Val: tokenSc},
		{Key: sym("amount"), Val: amountSc},
		{Key: sym("last_deposit_at"), Val: lastDepositSc},
	}
	record, err := xdr.NewScVal(xdr.ScValTypeScvMap, &entries)
	if err != nil {
		t.Fatal(err)
	}
	resultXDR, err := xdr.MarshalBase64(record)
	if err != nil {
		t.Fatal(err)
	}
	return resultXDR
}

// poolChainChain wires a fundedChain whose SimulateTransaction always
// answers a get_pool call with poolAmountRaw (present) or, for
// poolAmountRaw == nil, Option::None — the withdraw invocation itself is
// never actually reached in these tests because they exercise
// PoolWithdrawXDR's pre-checks, which return before simulation.
func poolChainChain(t *testing.T, poolAmountRaw *big.Int) *portstest.FakeChain {
	t.Helper()
	chain := fundedChain(t, 1)
	chain.SimulateTransactionFunc = func(ctx context.Context, unsignedXDR string) (ports.SimulateResult, error) {
		if poolAmountRaw == nil {
			none := xdr.ScVal{Type: xdr.ScValTypeScvVoid}
			resultXDR, err := xdr.MarshalBase64(none)
			if err != nil {
				t.Fatal(err)
			}
			return ports.SimulateResult{Success: true, TransactionDataXDR: emptySorobanData(t), ResultXDR: resultXDR}, nil
		}
		return ports.SimulateResult{
			Success:            true,
			TransactionDataXDR: emptySorobanData(t),
			ResultXDR:          poolRecordResultXDR(t, testTokenID, poolAmountRaw),
		}, nil
	}
	return chain
}

// TestPoolWithdrawXDR_ChainBalanceBelowRequestedIsRejected is the regression
// test for the "The network rejected this" pool withdraw bug: when the
// contract's own get_pool shows less than the requested amount, the request
// must be refused up front with errInsufficientBalance, not left to reach
// the contract and fail as an opaque errSimulationFailed.
func TestPoolWithdrawXDR_ChainBalanceBelowRequestedIsRejected(t *testing.T) {
	chain := poolChainChain(t, big.NewInt(5_000_000)) // 0.5, less than the 10 requested
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), chain)

	_, err := svc.PoolWithdrawXDR(context.Background(), testSender, "10")
	if !errors.Is(err, errInsufficientBalance) {
		t.Fatalf("got %v, want errInsufficientBalance", err)
	}
}

// TestPoolWithdrawXDR_NoChainPoolRecordIsRejected covers the same failure
// mode when the contract has no pool record for owner at all (Option::None).
func TestPoolWithdrawXDR_NoChainPoolRecordIsRejected(t *testing.T) {
	chain := poolChainChain(t, nil)
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), chain)

	_, err := svc.PoolWithdrawXDR(context.Background(), testSender, "10")
	if !errors.Is(err, errInsufficientBalance) {
		t.Fatalf("got %v, want errInsufficientBalance", err)
	}
}

// TestPoolWithdrawXDR_ChainUnreadableFallsBackToSimulation pins today's
// behavior when chainPoolRecord can't get an answer (RPC hiccup, decode
// failure): the pre-check must not guess, and control falls through to the
// contract's own simulation — same as before this fix.
func TestPoolWithdrawXDR_ChainUnreadableFallsBackToSimulation(t *testing.T) {
	chain := fundedChain(t, 1) // default fixture: Success:true, ResultXDR == "" (ok=false)
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), chain)

	if _, err := svc.PoolWithdrawXDR(context.Background(), testSender, "10"); err != nil {
		t.Fatalf("expected fallback to simulation to succeed, got %v", err)
	}
}

// TestPoolWithdrawXDR_InsufficientNativeFeeHeadroomRejected is the
// withdraw-side twin of TestPoolDepositXDR_NativeReservesBaseBalance: a
// wallet with too little native XLM left to pay its own transaction fee
// must be refused with the specific errInsufficientFee, not left to fail
// the transaction opaquely.
func TestPoolWithdrawXDR_InsufficientNativeFeeHeadroomRejected(t *testing.T) {
	chain := poolChainChain(t, big.NewInt(1_000_000_000)) // plenty in the pool
	chain.GetAccountFunc = func(ctx context.Context, address string) (ports.AccountInfo, error) {
		return ports.AccountInfo{
			Address: address, Sequence: 1, Exists: true,
			Balances: []ports.Balance{
				{AssetCode: testAssetCode, AssetIssuer: testAssetIssuer, Balance: "1000.0000000"},
				{AssetCode: "native", Balance: "1.0000000"}, // below the 1.5 XLM headroom
			},
		}, nil
	}
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), chain)

	_, err := svc.PoolWithdrawXDR(context.Background(), testSender, "10")
	if !errors.Is(err, errInsufficientFee) {
		t.Fatalf("got %v, want errInsufficientFee", err)
	}
}

// TestPoolWithdrawXDR_IssuedAssetNoTrustlineRejected is the withdraw-side
// twin of the deposit trustline preflight: the contract's withdraw transfers
// contract -> owner, so a missing trustline must be caught the same way
// deposit's sender-side transfer already is.
func TestPoolWithdrawXDR_IssuedAssetNoTrustlineRejected(t *testing.T) {
	chain := poolChainChain(t, big.NewInt(1_000_000_000))
	chain.GetTrustlineFunc = func(context.Context, string, string, string) (ports.TrustlineInfo, error) {
		return ports.TrustlineInfo{Exists: false}, nil
	}
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), chain)

	_, err := svc.PoolWithdrawXDR(context.Background(), testSender, "10")
	if !errors.Is(err, errSenderNoTrustline) {
		t.Fatalf("got %v, want errSenderNoTrustline", err)
	}
}

// TestSync_RepairsPoolCacheFromChain is the self-heal regression test: when
// the cache disagrees with the contract's own get_pool, Sync corrects the
// cache row in place (reconcilePoolWithChain) instead of continuing to
// offer an amount the contract will reject.
func TestSync_RepairsPoolCacheFromChain(t *testing.T) {
	repo := newFakeRepo()
	if err := repo.RecordDeposit(context.Background(), testSender, "100000000", testDecimals, 1); err != nil {
		t.Fatalf("seed RecordDeposit: %v", err)
	}
	chain := poolChainChain(t, big.NewInt(30_000_000)) // chain says 3, cache says 10
	svc := newServiceWithRepo(testConfig(), repo, chain)

	view, err := svc.Sync(context.Background(), testSender)
	if err != nil {
		t.Fatalf("Sync: %v", err)
	}
	if view.Pool.AmountRaw != "30000000" {
		t.Errorf("Sync Pool.AmountRaw = %q, want %q (repaired from chain)", view.Pool.AmountRaw, "30000000")
	}
	if view.Pool.ChainVerified == nil || !*view.Pool.ChainVerified {
		t.Error("Pool.ChainVerified should be true after a successful repair")
	}
	pool, _, err := repo.GetPool(context.Background(), testSender)
	if err != nil {
		t.Fatalf("GetPool: %v", err)
	}
	if pool.AmountRaw != "30000000" {
		t.Errorf("repo AmountRaw = %q, want %q (cache actually corrected)", pool.AmountRaw, "30000000")
	}
}

// TestSync_ChainUnreadableLeavesPoolCacheAlone pins today's behavior when
// the chain can't be read: the cache must never be guessed at, only
// corrected from a definite decoded answer.
func TestSync_ChainUnreadableLeavesPoolCacheAlone(t *testing.T) {
	repo := newFakeRepo()
	if err := repo.RecordDeposit(context.Background(), testSender, "100000000", testDecimals, 1); err != nil {
		t.Fatalf("seed RecordDeposit: %v", err)
	}
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1)) // default fixture: ok=false

	view, err := svc.Sync(context.Background(), testSender)
	if err != nil {
		t.Fatalf("Sync: %v", err)
	}
	if view.Pool.AmountRaw != "100000000" {
		t.Errorf("Sync Pool.AmountRaw = %q, want unchanged %q", view.Pool.AmountRaw, "100000000")
	}
	if view.Pool.ChainVerified != nil {
		t.Error("Pool.ChainVerified should be nil (couldn't check), not a guessed answer")
	}
}

// TestConfirmPoolWithdraw_CacheMissDoesNotFailTheCall is the regression test
// for the sessizce no-op bug turned into an ordinary 200: an on-chain
// withdraw already succeeded by the time this is called, so a cache row
// that's missing or already drained further than amountStr must not be
// surfaced to the caller as an error — reconcilePoolWithChain's job (via the
// next Sync), not ConfirmPoolWithdraw's, is to correct the cache.
func TestConfirmPoolWithdraw_CacheMissDoesNotFailTheCall(t *testing.T) {
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), fundedChain(t, 1))
	if err := svc.ConfirmPoolWithdraw(context.Background(), testSender, "10"); err != nil {
		t.Fatalf("ConfirmPoolWithdraw with no pool row: got %v, want nil", err)
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

// TestSync_IncludesTerminalChequesButSkipsTheirChainVerification is the
// regression test for the Activity feed report: a completed cheque used to
// be excluded from /sync entirely (ListActiveForAddress's old terminal-state
// filter), which made a finished send/receive disappear from both parties'
// history within seconds. It must still come back — but, since its state
// can never change again, without spending a chain simulate call re-verifying it.
func TestSync_IncludesTerminalChequesButSkipsTheirChainVerification(t *testing.T) {
	// Baseline: an empty-pool, no-cheques Sync still calls SimulateTransaction
	// once for the pool side's own chain reconciliation (a sibling feature,
	// not under test here) — so the terminal-cheque case below must be
	// compared against this baseline, not against zero.
	baselineChain := fundedChain(t, 1)
	baselineSvc := newServiceWithRepo(testConfig(), newFakeRepo(), baselineChain)
	if _, err := baselineSvc.Sync(context.Background(), testReceiver); err != nil {
		t.Fatalf("baseline Sync: %v", err)
	}

	repo := newFakeRepo()
	seedCheque(t, repo, StateKapandi)
	chain := fundedChain(t, 1)
	svc := newServiceWithRepo(testConfig(), repo, chain)

	view, err := svc.Sync(context.Background(), testReceiver)
	if err != nil {
		t.Fatalf("Sync: %v", err)
	}
	if len(view.Cheques) != 1 {
		t.Fatalf("got %d cheques, want 1 (terminal cheque must still be returned)", len(view.Cheques))
	}
	if view.Cheques[0].State != StateKapandi {
		t.Errorf("state = %v, want %v", view.Cheques[0].State, StateKapandi)
	}
	if view.Cheques[0].ChainVerified != nil {
		t.Error("ChainVerified should stay nil for a terminal cheque — it was never checked")
	}
	if chain.SimulateTransactionCalls != baselineChain.SimulateTransactionCalls {
		t.Errorf("SimulateTransactionCalls = %d, want %d (same as the no-cheques baseline — a terminal cheque must never be re-verified)",
			chain.SimulateTransactionCalls, baselineChain.SimulateTransactionCalls)
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

func TestPoolDepositXDR_Preflight(t *testing.T) {
	for _, tc := range []struct {
		name      string
		trustline bool
		lookupErr error
		amount    string
		want      error
	}{
		{"missing trustline", false, nil, "25", errSenderNoTrustline},
		{"lookup unavailable", false, errors.New("offline"), "25", errChainUnavailable},
		{"insufficient token balance", true, nil, "1001", errInsufficientBalance},
		{"funded token balance", true, nil, "25", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			chain := fundedChain(t, 1)
			chain.GetTrustlineFunc = func(ctx context.Context, address, code, issuer string) (ports.TrustlineInfo, error) {
				if address != testSender || code != testAssetCode || issuer != testAssetIssuer {
					t.Fatal("preflight checked the wrong account or asset")
				}
				return ports.TrustlineInfo{Exists: tc.trustline}, tc.lookupErr
			}
			svc := newServiceWithRepo(testConfig(), newFakeRepo(), chain)
			_, err := svc.PoolDepositXDR(context.Background(), testSender, tc.amount)
			if !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
			if tc.want != nil && chain.SimulateTransactionCalls != 0 {
				t.Fatal("invalid deposit reached simulation")
			}
		})
	}
}

func TestPoolDepositXDR_NativeDoesNotRequireTrustline(t *testing.T) {
	cfg := testConfig()
	cfg.AssetCode, cfg.AssetIssuer = "native", ""
	chain := fundedChain(t, 1)
	chain.GetAccountFunc = func(ctx context.Context, address string) (ports.AccountInfo, error) {
		return ports.AccountInfo{Exists: true, Address: address, Sequence: 1,
			Balances: []ports.Balance{{AssetCode: "native", Balance: "100"}}}, nil
	}
	chain.GetTrustlineFunc = func(context.Context, string, string, string) (ports.TrustlineInfo, error) {
		t.Fatal("native asset must not require a trustline")
		return ports.TrustlineInfo{}, nil
	}
	svc := newServiceWithRepo(cfg, newFakeRepo(), chain)
	if _, err := svc.PoolDepositXDR(context.Background(), testSender, "25"); err != nil {
		t.Fatal(err)
	}
}

// TestPoolDepositXDR_NativeReservesBaseBalance is the regression test for
// the pool "the network rejected this" report: depositing an amount that
// would leave the account below Stellar's own reserve must be refused with
// the clearer errInsufficientBalance BEFORE ever reaching simulation, not
// left to fail as an opaque contract-level token transfer rejection.
func TestPoolDepositXDR_NativeReservesBaseBalance(t *testing.T) {
	cfg := testConfig()
	cfg.AssetCode, cfg.AssetIssuer = "native", ""
	chain := fundedChain(t, 1)
	// 10 XLM total; nativeReserveHeadroomRaw (1.5 XLM) must come off the top.
	chain.GetAccountFunc = func(ctx context.Context, address string) (ports.AccountInfo, error) {
		return ports.AccountInfo{Exists: true, Address: address, Sequence: 1,
			Balances: []ports.Balance{{AssetCode: "native", Balance: "10.0000000"}}}, nil
	}
	svc := newServiceWithRepo(cfg, newFakeRepo(), chain)

	if _, err := svc.PoolDepositXDR(context.Background(), testSender, "9"); !errors.Is(err, errInsufficientBalance) {
		t.Fatalf("depositing into the reserve: got %v, want errInsufficientBalance", err)
	}
	if chain.SimulateTransactionCalls != 0 {
		t.Fatal("a deposit that dips into the reserve must never reach simulation")
	}
	if _, err := svc.PoolDepositXDR(context.Background(), testSender, "8"); err != nil {
		t.Fatalf("depositing comfortably within the reserve: %v", err)
	}
}
