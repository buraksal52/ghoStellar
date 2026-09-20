package cheque

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"time"

	"github.com/oklog/ulid/v2"
	"github.com/stellar/go-stellar-sdk/xdr"

	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/pkg/money"
	"github.com/local-payment/backend/pkg/stellarx"
	"github.com/local-payment/backend/ports"
)

// Cheque validity (p2p doc §0 rule 2 / §9.H1), kept in sync with the contract.
const (
	chequeValidity = 7 * 24 * time.Hour
	// Ledger close time varies; ~5s/ledger is Stellar's design target, used
	// only to size the force_collect pre-auth entry's expiration ledger —
	// an approximation is fine because the CONTRACT'S OWN check is against
	// ledger timestamp seconds, not this estimate (D7).
	approxLedgersPerWeek = uint32(7 * 24 * 60 * 60 / 5)
)

var ErrDBNotReadyErr = errors.New(ErrDBNotReady)

type Config struct {
	EscrowContractID  string
	TokenContractID   string // the SAC address pay-escrow moves (plan's Açık Varsayım #1: one asset for the MVP)
	AssetCode         string
	AssetIssuer       string
	Decimals          uint8
	NetworkPassphrase string
}

type Service struct {
	cfg   Config
	repos func() (chequeRepo, error)
	chain ports.ChainGateway
}

func NewService(cfg Config, pool *dbx.Pool, chain ports.ChainGateway) *Service {
	return &Service{cfg: cfg, chain: chain, repos: func() (chequeRepo, error) {
		p := pool.Get()
		if p == nil {
			return nil, ErrDBNotReadyErr
		}
		return NewRepository(p), nil
	}}
}

// newServiceWithRepo is the test seam: the same Service, wired to a
// caller-supplied repo (production *Repository or a test fake) instead of a
// *dbx.Pool. Package-private — only this package's tests construct one.
func newServiceWithRepo(cfg Config, repo chequeRepo, chain ports.ChainGateway) *Service {
	return &Service{cfg: cfg, chain: chain, repos: func() (chequeRepo, error) { return repo, nil }}
}

// asset returns the configured asset's identity, shared by every code path
// that must parse a caller-supplied amount string through pkg/money instead
// of touching it as a raw string (CLAUDE.md: money is never a bare string
// off the API boundary without going through money.ParseAmount first).
func (s *Service) asset() money.AssetID {
	return money.AssetID{ContractID: s.cfg.TokenContractID, Code: s.cfg.AssetCode, Issuer: s.cfg.AssetIssuer}
}

func (s *Service) simulator() stellarx.Simulator {
	return func(ctx context.Context, unsignedXDR string) (stellarx.SimulationResult, error) {
		res, err := s.chain.SimulateTransaction(ctx, unsignedXDR)
		if err != nil {
			return stellarx.SimulationResult{}, err
		}
		if !res.Success {
			return stellarx.SimulationResult{}, fmt.Errorf("%w: %s", errSimulationFailed, res.Error)
		}
		return stellarx.SimulationResult{TransactionDataXDR: res.TransactionDataXDR, AuthXDR: res.AuthXDR}, nil
	}
}

// CreateChequeResult is what POST /cheques returns: the unsigned lock XDR
// plus the force_collect pre-authorization payload the device must also
// sign (two separate signatures from the same key, per the plan's
// "Kritik Mimari Karar").
type CreateChequeResult struct {
	ChequeID           string    `json:"chequeId"`
	LockXDR            string    `json:"lockXdr"`
	PreauthEntryXDR    string    `json:"preauthEntryXdr"`    // unsigned SorobanAuthorizationEntry, base64
	PreauthPayloadHash string    `json:"preauthPayloadHash"` // base64 sha256 the device must sign
	ExpiresAt          time.Time `json:"expiresAt"`
}

// CreateCheque runs the p2p doc's §9.A validations (A1, A4/F3, A5, A6 — A3
// is enforced by the reservation's partial unique index) and, once they
// pass, reserves the amount and returns everything the device needs to
// sign: the unsigned `lock` transaction and the unsigned force_collect
// pre-authorization entry.
func (s *Service) CreateCheque(ctx context.Context, sender, receiver, amountStr, requestID string) (CreateChequeResult, error) {
	repo, err := s.repos()
	if err != nil {
		return CreateChequeResult{}, err
	}

	if sender == receiver {
		return CreateChequeResult{}, errSelfTransfer
	}
	if !validRequestID(requestID) {
		return CreateChequeResult{}, errInvalidRequestID
	}
	if !stellarx.IsValidAccountAddress(receiver) {
		return CreateChequeResult{}, errInvalidReceiver
	}
	amount, err := money.ParseAmount(amountStr, s.asset(), s.cfg.Decimals)
	if err != nil || amount.Raw.Sign() <= 0 {
		return CreateChequeResult{}, errInvalidAmount
	}

	trustline, err := s.chain.GetTrustline(ctx, receiver, s.cfg.AssetCode, s.cfg.AssetIssuer)
	if err != nil {
		return CreateChequeResult{}, fmt.Errorf("%w: %v", errChainUnavailable, err)
	}
	if !trustline.Exists {
		return CreateChequeResult{}, errReceiverNoTrustline
	}

	senderAccount, err := s.chain.GetAccount(ctx, sender)
	if err != nil {
		return CreateChequeResult{}, fmt.Errorf("%w: %v", errChainUnavailable, err)
	}
	if !hasSufficientBalance(senderAccount, s.cfg.AssetCode, s.cfg.AssetIssuer, amount.Raw, s.cfg.Decimals) {
		return CreateChequeResult{}, errInsufficientBalance
	}

	chequeID := ulid.Make()
	expiresAt := time.Now().Add(chequeValidity)

	c := Cheque{
		ID:              chequeID.String(),
		SenderAddress:   sender,
		ReceiverAddress: receiver,
		RequestID:       requestID,
		TokenContract:   s.cfg.TokenContractID,
		AmountRaw:       amount.Raw.String(),
		Decimals:        s.cfg.Decimals,
		State:           StateImzaliRezerve,
		ExpiresAt:       expiresAt,
	}
	if err := repo.CreateReservedCheque(ctx, c); err != nil {
		if errors.Is(err, ErrAlreadyActiveInRepo) {
			return CreateChequeResult{}, errAlreadyActive
		}
		if errors.Is(err, ErrRequestUsedInRepo) {
			return CreateChequeResult{}, errRequestUsed
		}
		return CreateChequeResult{}, fmt.Errorf("cheque: create reservation: %w", err)
	}

	lockArgs, err := scArgs(
		scAddr(sender), scBytes(chequeID[:]), scAddr(receiver),
		scAddr(s.cfg.TokenContractID), scI128(amount.Raw), scU64(uint64(expiresAt.Unix())),
	)
	if err != nil {
		return CreateChequeResult{}, fmt.Errorf("cheque: build lock args: %w", err)
	}
	lockOp, err := stellarx.InvokeContract(s.cfg.EscrowContractID, sender, "lock", lockArgs...)
	if err != nil {
		return CreateChequeResult{}, fmt.Errorf("cheque: build lock op: %w", err)
	}
	lockXDR, err := stellarx.AssembleInvocation(ctx, s.simulator(), s.cfg.NetworkPassphrase, sender, senderAccount.Sequence, lockOp)
	if err != nil {
		return CreateChequeResult{}, fmt.Errorf("cheque: assemble lock tx: %w", err)
	}

	ledger, err := s.chain.GetLedger(ctx)
	if err != nil {
		return CreateChequeResult{}, fmt.Errorf("%w: %v", errChainUnavailable, err)
	}
	nonce, err := randomNonce()
	if err != nil {
		return CreateChequeResult{}, fmt.Errorf("cheque: generate nonce: %w", err)
	}
	entryXDR, payloadHash, err := stellarx.BuildForceCollectAuthEntry(
		s.cfg.NetworkPassphrase, s.cfg.EscrowContractID,
		sender, receiver, s.cfg.TokenContractID, amount.Raw, chequeID[:],
		uint64(expiresAt.Unix()), uint32(ledger.Sequence)+approxLedgersPerWeek, nonce,
	)
	if err != nil {
		return CreateChequeResult{}, fmt.Errorf("cheque: build force_collect auth entry: %w", err)
	}

	s.audit(ctx, repo, sender, "cheque.lock_xdr_issued", map[string]string{"chequeId": c.ID, "receiver": receiver, "amount": amount.String()})

	return CreateChequeResult{
		ChequeID:           c.ID,
		LockXDR:            lockXDR,
		PreauthEntryXDR:    base64.StdEncoding.EncodeToString(entryXDR),
		PreauthPayloadHash: base64.StdEncoding.EncodeToString(payloadHash),
		ExpiresAt:          expiresAt,
	}, nil
}

// audit best-effort records an append-only audit_log entry (SERVICE.md
// #11) — never on the request's error path, since an audit write failing
// must never make a genuinely successful operation look like a failure to
// the caller. There is no logger at this layer yet (pkg/obs's logger lives
// in cmd/*/main.go), so a failed audit write is silently dropped; this is
// an accepted, documented gap rather than an oversight — audit_log is an
// observability aid, not a correctness dependency.
func (s *Service) audit(ctx context.Context, repo chequeRepo, actor, action string, details any) {
	_ = repo.InsertAudit(ctx, actor, action, details)
}

// StorePreauth saves the device-signed force_collect authorization entry
// (base64 XDR, with Credentials.Address.Signature now filled in) so it can
// be handed to the receiver later. Only the cheque's own sender may store
// this — otherwise anyone who learns the (unguessable but not secret) cheque
// ID could overwrite the real sender's signed authorization with garbage,
// permanently breaking the receiver's force_collect path.
func (s *Service) StorePreauth(ctx context.Context, chequeID, caller, signedEntryXDR string) error {
	repo, err := s.repos()
	if err != nil {
		return err
	}
	c, err := repo.GetCheque(ctx, chequeID)
	if err != nil {
		return mapRepoErr(err)
	}
	if c.SenderAddress != caller {
		return errNotFound // not "forbidden": don't confirm the ID is valid to a non-party
	}
	return repo.SetPreauthEntry(ctx, chequeID, signedEntryXDR)
}

// ConfirmLock is called once the device has submitted the signed lock XDR
// via pay-tx-service and it succeeded — it moves the cheque from
// IMZALI_REZERVE to HAVUZDA. See SERVICE.md's "Kapsam sınırlaması" for why
// this MVP takes the caller's word (backed by tx-service's own direct
// chain interaction) rather than independently re-deriving state from a
// ScVal-decoded on-chain read. Only the cheque's own sender may confirm it
// (the sender is the only party who ever holds the lock tx's signature).
func (s *Service) ConfirmLock(ctx context.Context, chequeID, caller, txHash string) error {
	repo, err := s.repos()
	if err != nil {
		return err
	}
	c, err := repo.GetCheque(ctx, chequeID)
	if err != nil {
		return mapRepoErr(err)
	}
	if c.SenderAddress != caller {
		return errNotFound
	}
	if err := repo.SetLockTxHash(ctx, chequeID, txHash); err != nil {
		return err
	}
	if err := repo.Transition(ctx, chequeID, StateImzaliRezerve, StateHavuzda, "user_action", txHash); err != nil {
		if errors.Is(err, ErrBadTransitionInRepo) {
			return nil // D3: already applied (replay-safe)
		}
		return err
	}
	s.audit(ctx, repo, caller, "cheque.lock_confirmed", map[string]string{"chequeId": chequeID, "txHash": txHash})
	return nil
}

// ClaimXDR builds the unsigned claim transaction for the cheque's receiver.
//
// A cheque still recorded as IMZALI_REZERVE/FONLANIYOR locally is not
// automatically refused as terminal any more: the sender's own
// `confirm-lock` (ConfirmLock, "the caller's word") can be lost to a
// network blip after the lock transaction itself already succeeded on
// chain, leaving the receiver unable to ever claim their own funded cheque.
// Before giving up, this re-derives the truth from the contract's own
// get_cheque (SERVICE.md #1) and repairs the local row when the chain
// disagrees, in both directions: already Funded (repair to HAVUZDA and
// proceed), or already Claimed (repair to TALEP_EDILDI and answer
// ErrAlreadyClaimed instead of a generic terminal-state refusal — the
// receiver's own earlier claim submit may have succeeded while its
// ConfirmClaim calls back failed).
func (s *Service) ClaimXDR(ctx context.Context, chequeID, receiver string) (string, error) {
	repo, err := s.repos()
	if err != nil {
		return "", err
	}
	c, err := repo.GetCheque(ctx, chequeID)
	if err != nil {
		return "", mapRepoErr(err)
	}
	if c.ReceiverAddress != receiver {
		return "", errInvalidReceiver
	}

	receiverAccount, err := s.chain.GetAccount(ctx, receiver)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errChainUnavailable, err)
	}

	if c.State != StateHavuzda {
		switch c.State {
		case StateImzaliRezerve, StateFonlaniyor:
			record, present, ok := s.chainChequeRecord(ctx, c, receiverAccount.Sequence)
			if !ok {
				return "", errTerminalState
			}
			switch {
			case present && record.State == "Funded":
				if terr := repo.Transition(ctx, chequeID, c.State, StateHavuzda, "chain_verified", c.LockTxHash); terr != nil &&
					!errors.Is(terr, ErrBadTransitionInRepo) {
					return "", terr
				}
				s.audit(ctx, repo, receiver, "cheque.lock_repaired_from_chain", map[string]string{"chequeId": chequeID})
				// Fall through below with c treated as HAVUZDA.
			case present && record.State == "Claimed":
				if terr := repo.Transition(ctx, chequeID, c.State, StateTalepEdildi, "chain_verified", c.LockTxHash); terr != nil &&
					!errors.Is(terr, ErrBadTransitionInRepo) {
					return "", terr
				}
				return "", errAlreadyClaimed
			default:
				// Not yet funded on chain (or absent): a real "not yet",
				// distinct from a permanent terminal-state refusal.
				return "", errNotFunded
			}
		default:
			return "", errTerminalState
		}
	}
	if time.Now().After(c.ExpiresAt) {
		return "", errExpired
	}

	idBytes, err := decodeULID(chequeID)
	if err != nil {
		return "", err
	}
	claimArgs, err := scArgs(scBytes(idBytes))
	if err != nil {
		return "", err
	}
	op, err := stellarx.InvokeContract(s.cfg.EscrowContractID, receiver, "claim", claimArgs...)
	if err != nil {
		return "", err
	}
	return stellarx.AssembleInvocation(ctx, s.simulator(), s.cfg.NetworkPassphrase, receiver, receiverAccount.Sequence, op)
}

// ConfirmClaim moves a cheque from HAVUZDA to TALEP_EDILDI (money has moved;
// ONAYLANDI/KAPANDI follow once the receiver acks the receipt, p2p doc §9.I).
// Only the cheque's own receiver may confirm it.
func (s *Service) ConfirmClaim(ctx context.Context, chequeID, caller, txHash string) error {
	repo, err := s.repos()
	if err != nil {
		return err
	}
	c, err := repo.GetCheque(ctx, chequeID)
	if err != nil {
		return mapRepoErr(err)
	}
	if c.ReceiverAddress != caller {
		return errNotFound
	}
	if err := repo.Transition(ctx, chequeID, StateHavuzda, StateTalepEdildi, "user_action", txHash); err != nil {
		if errors.Is(err, ErrBadTransitionInRepo) {
			return nil
		}
		return err
	}
	s.audit(ctx, repo, caller, "cheque.claimed", map[string]string{"chequeId": chequeID, "txHash": txHash})
	return nil
}

// AcknowledgeReceipt is the p2p doc §9.I receipt: purely a ledger-closing
// step, the money already moved at claim time. Only the cheque's own
// receiver may acknowledge it.
func (s *Service) AcknowledgeReceipt(ctx context.Context, chequeID, caller string) error {
	repo, err := s.repos()
	if err != nil {
		return err
	}
	c, err := repo.GetCheque(ctx, chequeID)
	if err != nil {
		return mapRepoErr(err)
	}
	if c.ReceiverAddress != caller {
		return errNotFound
	}
	if err := repo.Transition(ctx, chequeID, StateTalepEdildi, StateOnaylandi, "user_action", ""); err != nil && !errors.Is(err, ErrBadTransitionInRepo) {
		return err
	}
	if err := repo.Transition(ctx, chequeID, StateOnaylandi, StateKapandi, "user_action", ""); err != nil && !errors.Is(err, ErrBadTransitionInRepo) {
		return err
	}
	return nil
}

// ForceCollectXDR builds the unsigned force_collect transaction, submitted
// by the receiver but authorized by the sender's stored pre-signed entry
// (p2p doc §5/§6.3).
func (s *Service) ForceCollectXDR(ctx context.Context, chequeID, receiver string) (string, error) {
	repo, err := s.repos()
	if err != nil {
		return "", err
	}
	c, err := repo.GetCheque(ctx, chequeID)
	if err != nil {
		return "", mapRepoErr(err)
	}
	if c.ReceiverAddress != receiver {
		return "", errInvalidReceiver
	}
	if c.State != StateImzaliRezerve && c.State != StateFonlaniyor {
		return "", errTerminalState // already Funded (use claim) or already terminal
	}
	if c.PreauthEntryXDR == "" {
		return "", errBadRequest
	}

	entryBytes, err := base64.StdEncoding.DecodeString(c.PreauthEntryXDR)
	if err != nil {
		return "", fmt.Errorf("cheque: decode stored preauth entry: %w", err)
	}
	amountRaw, ok := new(big.Int).SetString(c.AmountRaw, 10)
	if !ok {
		return "", fmt.Errorf("cheque: corrupt amount_raw %q", c.AmountRaw)
	}
	idBytes, err := decodeULID(chequeID)
	if err != nil {
		return "", err
	}

	receiverAccount, err := s.chain.GetAccount(ctx, receiver)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errChainUnavailable, err)
	}

	fcArgs, err := scArgs(
		scAddr(c.SenderAddress), scBytes(idBytes), scAddr(c.ReceiverAddress),
		scAddr(c.TokenContract), scI128(amountRaw), scU64(uint64(c.ExpiresAt.Unix())),
	)
	if err != nil {
		return "", err
	}
	op, err := stellarx.InvokeContract(s.cfg.EscrowContractID, receiver, "force_collect", fcArgs...)
	if err != nil {
		return "", err
	}
	if err := stellarx.AttachAuthEntry(op, entryBytes); err != nil {
		return "", err
	}
	xdrStr, err := stellarx.AssembleInvocation(ctx, s.simulator(), s.cfg.NetworkPassphrase, receiver, receiverAccount.Sequence, op)
	if err != nil {
		return "", err
	}

	_ = repo.Transition(ctx, chequeID, c.State, StateZorlaTahsilDenendi, "user_action", "") // best-effort marker; terminal outcome recorded on confirm
	return xdrStr, nil
}

// ConfirmForceCollect records force_collect's on-chain outcome:
// Collected -> KAPANDI, Bounced -> KARSILIKSIZ (D2/D8 — the sender is never
// treated as in debt either way). Only the cheque's own receiver may report
// this — collected=false marks the cheque KARSILIKSIZ ("bounced"), the most
// consequential state in the product, and must not be forgeable by a
// non-party.
func (s *Service) ConfirmForceCollect(ctx context.Context, chequeID, caller, txHash string, collected bool) error {
	repo, err := s.repos()
	if err != nil {
		return err
	}
	c, err := repo.GetCheque(ctx, chequeID)
	if err != nil {
		return mapRepoErr(err)
	}
	if c.ReceiverAddress != caller {
		return errNotFound
	}
	to := StateKarsiliksiz
	if collected {
		to = StateKapandi
	}
	if err := repo.Transition(ctx, chequeID, StateZorlaTahsilDenendi, to, "user_action", txHash); err != nil && !errors.Is(err, ErrBadTransitionInRepo) {
		return err
	}
	s.audit(ctx, repo, caller, "cheque.force_collect_confirmed", map[string]any{"chequeId": chequeID, "txHash": txHash, "collected": collected})
	return nil
}

// ExpiredFundedCheques returns every HAVUZDA cheque past its expiry — what
// pay-scheduler-service sweeps to submit a permissionless refund for (p2p
// doc §6.2, §9.B1).
func (s *Service) ExpiredFundedCheques(ctx context.Context) ([]Cheque, error) {
	repo, err := s.repos()
	if err != nil {
		return nil, err
	}
	return repo.ExpiredFundedCheques(ctx, time.Now())
}

// MarkRefunded records a scheduler-submitted permissionless refund's
// outcome: HAVUZDA -> IADE_EDILEBILIR -> IADE_EDILDI in one call, since the
// scheduler only observes the already-completed submission (D9: nobody
// waited on the sender or receiver being online for this).
func (s *Service) MarkRefunded(ctx context.Context, chequeID, txHash string) error {
	repo, err := s.repos()
	if err != nil {
		return err
	}
	if err := repo.Transition(ctx, chequeID, StateHavuzda, StateIadeEdilebilir, "scheduler_sweep", ""); err != nil && !errors.Is(err, ErrBadTransitionInRepo) {
		return err
	}
	if err := repo.Transition(ctx, chequeID, StateIadeEdilebilir, StateIadeEdildi, "scheduler_sweep", txHash); err != nil && !errors.Is(err, ErrBadTransitionInRepo) {
		return err
	}
	s.audit(ctx, repo, "system", "cheque.refunded", map[string]string{"chequeId": chequeID, "txHash": txHash})
	return nil
}

// Sync is the Forced Sync endpoint: every pending cheque and the pool
// balance for address, in one call (p2p doc §1, §5).
//
// SERVICE.md #1: alongside the local Postgres view (the historically sole
// source), this now cross-checks every cheque and the pool against the
// contract's own get_cheque/get_pool via a read-only simulateTransaction —
// an independent, chain-derived signal instead of relying purely on the
// write endpoints + confirm-* + scheduler sweep keeping the cache honest.
// Deliberately additive, not a replacement: the ScVal decode this depends
// on (pkg/stellarx's DecodeChequeRecord/DecodePoolRecord) has not been
// exercised against a live network, so a decode/simulate failure here logs
// nothing (no logger at this layer, see cheque.audit's doc comment) and
// leaves ChainVerified nil rather than ever failing the whole request or
// silently asserting a wrong answer.
func (s *Service) Sync(ctx context.Context, address string) (SyncView, error) {
	repo, err := s.repos()
	if err != nil {
		return SyncView{}, err
	}
	cheques, err := repo.ListActiveForAddress(ctx, address)
	if err != nil {
		return SyncView{}, err
	}
	pool, _, err := repo.GetPool(ctx, address)
	if err != nil {
		return SyncView{}, err
	}
	trustline, err := s.chain.GetTrustline(ctx, address, s.cfg.AssetCode, s.cfg.AssetIssuer)
	if err != nil {
		return SyncView{}, fmt.Errorf("%w: %v", errChainUnavailable, err)
	}
	ledger, err := s.chain.GetLedger(ctx)
	if err != nil {
		return SyncView{}, fmt.Errorf("%w: %v", errChainUnavailable, err)
	}

	callerAccount, err := s.chain.GetAccount(ctx, address)
	if err == nil {
		for i := range cheques {
			cheques[i].ChainVerified = s.verifyChequeOnChain(ctx, cheques[i], callerAccount.Sequence)
		}
		pool.ChainVerified = s.verifyPoolOnChain(ctx, address, pool, callerAccount.Sequence)
	}

	return SyncView{
		Cheques:           cheques,
		Pool:              pool,
		TrustlineReady:    trustline.Exists,
		Ledger:            ledger.Sequence,
		ServerTimeUnix:    time.Now().Unix(),
		NetworkPassphrase: s.cfg.NetworkPassphrase,
	}, nil
}

// ---- Havuz (pool) ----------------------------------------------------

// PoolDepositXDR builds the unsigned deposit transaction. Always allowed
// (p2p doc §7) — no reservation, no balance pre-check beyond what the
// contract itself enforces atomically.
func (s *Service) PoolDepositXDR(ctx context.Context, owner, amountStr string) (string, error) {
	amount, err := money.ParseAmount(amountStr, s.asset(), s.cfg.Decimals)
	if err != nil || amount.Raw.Sign() <= 0 {
		return "", errInvalidAmount
	}
	ownerAccount, err := s.chain.GetAccount(ctx, owner)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errChainUnavailable, err)
	}
	if !ownerAccount.Exists {
		return "", errAccountNotFunded
	}
	if s.cfg.AssetCode != "native" && owner != s.cfg.AssetIssuer {
		trustline, err := s.chain.GetTrustline(ctx, owner, s.cfg.AssetCode, s.cfg.AssetIssuer)
		if err != nil {
			return "", fmt.Errorf("%w: %v", errChainUnavailable, err)
		}
		if !trustline.Exists {
			return "", errSenderNoTrustline
		}
	}
	if owner != s.cfg.AssetIssuer && !hasSufficientBalance(ownerAccount, s.cfg.AssetCode, s.cfg.AssetIssuer, amount.Raw, s.cfg.Decimals) {
		return "", errInsufficientBalance
	}
	depositArgs, err := scArgs(scAddr(owner), scAddr(s.cfg.TokenContractID), scI128(amount.Raw))
	if err != nil {
		return "", err
	}
	op, err := stellarx.InvokeContract(s.cfg.EscrowContractID, owner, "deposit", depositArgs...)
	if err != nil {
		return "", err
	}
	return stellarx.AssembleInvocation(ctx, s.simulator(), s.cfg.NetworkPassphrase, owner, ownerAccount.Sequence, op)
}

// PoolWithdrawXDR builds the unsigned withdraw transaction. Pool funds are
// withdrawable at any time; balance and authorization remain contract-checked.
func (s *Service) PoolWithdrawXDR(ctx context.Context, owner, amountStr string) (string, error) {
	amount, err := money.ParseAmount(amountStr, s.asset(), s.cfg.Decimals)
	if err != nil || amount.Raw.Sign() <= 0 {
		return "", errInvalidAmount
	}
	ownerAccount, err := s.chain.GetAccount(ctx, owner)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errChainUnavailable, err)
	}
	if !ownerAccount.Exists {
		return "", errAccountNotFunded
	}
	withdrawArgs, err := scArgs(scAddr(owner), scI128(amount.Raw))
	if err != nil {
		return "", err
	}
	op, err := stellarx.InvokeContract(s.cfg.EscrowContractID, owner, "withdraw", withdrawArgs...)
	if err != nil {
		return "", err
	}
	return stellarx.AssembleInvocation(ctx, s.simulator(), s.cfg.NetworkPassphrase, owner, ownerAccount.Sequence, op)
}

// ConfirmPoolDeposit records a confirmed on-chain deposit against the read
// cache. amountStr is the same caller-supplied decimal string every other
// money-accepting endpoint takes — it MUST go through money.ParseAmount
// before it reaches storage, or it silently becomes a raw (non-scaled)
// integer in a NUMERIC(40,0) column (CLAUDE.md: money is never a bare
// string off the API boundary).
func (s *Service) ConfirmPoolDeposit(ctx context.Context, owner, amountStr string, ledgerSeq int64) error {
	repo, err := s.repos()
	if err != nil {
		return err
	}
	amount, err := money.ParseAmount(amountStr, s.asset(), s.cfg.Decimals)
	if err != nil || amount.Raw.Sign() <= 0 {
		return errInvalidAmount
	}
	return repo.RecordDeposit(ctx, owner, amount.Raw.String(), s.cfg.Decimals, ledgerSeq)
}

func (s *Service) ConfirmPoolWithdraw(ctx context.Context, owner, amountStr string) error {
	repo, err := s.repos()
	if err != nil {
		return err
	}
	amount, err := money.ParseAmount(amountStr, s.asset(), s.cfg.Decimals)
	if err != nil || amount.Raw.Sign() <= 0 {
		return errInvalidAmount
	}
	return repo.RecordWithdraw(ctx, owner, amount.Raw.String())
}

// ---- SERVICE.md #1: chain cross-verification ---------------------------

// chainChequeRecord simulates the contract's own get_cheque for c and
// decodes the result. ok=false means "couldn't check" (a transient RPC
// hiccup, or an unverified ScVal encoding) — never treated as "not found
// on chain", which is a decoded answer (present=false) in its own right.
func (s *Service) chainChequeRecord(ctx context.Context, c Cheque, callerSequence int64) (record stellarx.ChequeRecordView, present, ok bool) {
	idBytes, err := decodeULID(c.ID)
	if err != nil {
		return stellarx.ChequeRecordView{}, false, false
	}
	idArg, err := scBytes(idBytes)()
	if err != nil {
		return stellarx.ChequeRecordView{}, false, false
	}
	op, err := stellarx.InvokeContract(s.cfg.EscrowContractID, c.ReceiverAddress, "get_cheque", idArg)
	if err != nil {
		return stellarx.ChequeRecordView{}, false, false
	}
	xdrStr, err := stellarx.AssembleInvocation(ctx, s.simulator(), s.cfg.NetworkPassphrase, c.ReceiverAddress, callerSequence, op)
	if err != nil {
		return stellarx.ChequeRecordView{}, false, false
	}
	result, err := s.chain.SimulateTransaction(ctx, xdrStr)
	if err != nil || !result.Success || result.ResultXDR == "" {
		return stellarx.ChequeRecordView{}, false, false
	}
	var resultVal xdr.ScVal
	if err := xdr.SafeUnmarshalBase64(result.ResultXDR, &resultVal); err != nil {
		return stellarx.ChequeRecordView{}, false, false
	}
	record, present, err = stellarx.DecodeChequeRecord(resultVal)
	if err != nil {
		return stellarx.ChequeRecordView{}, false, false
	}
	return record, present, true
}

// verifyChequeOnChain compares the contract's own get_cheque state against
// c's locally-recorded State. Returns nil (not false) when chainChequeRecord
// couldn't get an answer — that must never be reported as a mismatch; it
// means "couldn't check", which the client should treat the same as not
// having asked at all.
func (s *Service) verifyChequeOnChain(ctx context.Context, c Cheque, callerSequence int64) *bool {
	record, present, ok := s.chainChequeRecord(ctx, c, callerSequence)
	if !ok {
		return nil
	}
	matched := chequeStateMatchesChain(c.State, present, record.State)
	return &matched
}

// verifyPoolOnChain is verifyChequeOnChain's pool counterpart, cross-
// checking get_pool's amount against the local cache's amount_raw — the
// one thing pool.deposit/withdraw's confirm-* endpoints are trusted to
// keep honest without independent verification today.
func (s *Service) verifyPoolOnChain(ctx context.Context, owner string, pool PoolDeposit, callerSequence int64) *bool {
	ownerArg, err := scAddr(owner)()
	if err != nil {
		return nil
	}
	op, err := stellarx.InvokeContract(s.cfg.EscrowContractID, owner, "get_pool", ownerArg)
	if err != nil {
		return nil
	}
	xdrStr, err := stellarx.AssembleInvocation(ctx, s.simulator(), s.cfg.NetworkPassphrase, owner, callerSequence, op)
	if err != nil {
		return nil
	}
	result, err := s.chain.SimulateTransaction(ctx, xdrStr)
	if err != nil || !result.Success || result.ResultXDR == "" {
		return nil
	}
	var resultVal xdr.ScVal
	if err := xdr.SafeUnmarshalBase64(result.ResultXDR, &resultVal); err != nil {
		return nil
	}
	record, present, err := stellarx.DecodePoolRecord(resultVal)
	if err != nil {
		return nil
	}
	localAmount, ok := new(big.Int).SetString(pool.AmountRaw, 10)
	if !ok {
		return nil
	}
	var matched bool
	switch {
	case !present:
		matched = localAmount.Sign() == 0
	default:
		matched = record.Amount.Cmp(localAmount) == 0
	}
	return &matched
}

// chequeStateMatchesChain maps the contract's coarse ChequeState (or its
// absence) onto the local, finer-grained state machine's buckets — the
// pre-chain states (TASLAK/IMZALI_REZERVE) have no on-chain counterpart at
// all, so "absent on-chain" only matches those.
func chequeStateMatchesChain(local State, present bool, chainState string) bool {
	if !present {
		return local == StateTaslak || local == StateImzaliRezerve
	}
	switch chainState {
	case "Funded":
		return local == StateHavuzda || local == StateFonlaniyor || local == StateZorlaTahsilDenendi
	case "Claimed":
		return local == StateTalepEdildi || local == StateOnaylandi || local == StateKapandi
	case "Refunded":
		return local == StateIadeEdilebilir || local == StateIadeEdildi
	case "Collected":
		return local == StateKapandi || local == StateZorlaTahsilDenendi
	case "Bounced":
		return local == StateKarsiliksiz
	default:
		return false
	}
}

// ---- helpers -----------------------------------------------------------

// nativeReserveHeadroomRaw is a fixed 1.5 XLM (7-decimal raw units) held
// back from a native-XLM balance check: Stellar's base reserve (1 XLM,
// plus 0.5 XLM per subentry/trustline the account already carries) is not
// spendable, and every submitted transaction also needs its own network
// fee. Horizon's raw "native" balance figure includes that reserved
// portion — comparing against it directly (as this function used to)
// would approve a deposit/cheque amount that leaves the account unable to
// pay its own reserve, and the contract's own token transfer would then
// reject it in simulation ("the network rejected this") with no clearer
// reason than the generic cheque.simulation_failed/insufficient_balance a
// person already saw before submitting. Not applied to an issued asset,
// which carries no comparable reserve of its own.
var nativeReserveHeadroomRaw = big.NewInt(15_000_000)

func hasSufficientBalance(acc ports.AccountInfo, assetCode, assetIssuer string, amount *big.Int, decimals uint8) bool {
	for _, b := range acc.Balances {
		if b.AssetCode != assetCode || (assetCode != "native" && b.AssetIssuer != assetIssuer) {
			continue
		}
		bal, err := money.ParseAmount(b.Balance, money.AssetID{Code: assetCode, Issuer: assetIssuer}, decimals)
		if err != nil {
			return false
		}
		spendable := bal.Raw
		if assetCode == "native" {
			spendable = new(big.Int).Sub(spendable, nativeReserveHeadroomRaw)
		}
		return spendable.Cmp(amount) >= 0
	}
	return false
}

func randomNonce() (int64, error) {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return 0, err
	}
	n := int64(binary.BigEndian.Uint64(b[:]))
	if n < 0 {
		n = -n
	}
	return n, nil
}

func decodeULID(s string) ([]byte, error) {
	id, err := ulid.ParseStrict(s)
	if err != nil {
		return nil, fmt.Errorf("%w: bad cheque id", errBadRequest)
	}
	return id[:], nil
}

// scValFunc and scArgs let the ScVal-building call sites above read as a
// flat list of intent (scAddr(x), scI128(y), ...) instead of a wall of
// individual error checks, while still surfacing the first construction
// error instead of panicking.
type scValFunc func() (xdr.ScVal, error)

func scAddr(address string) scValFunc {
	return func() (xdr.ScVal, error) { return stellarx.ScAddress(address) }
}
func scBytes(b []byte) scValFunc  { return func() (xdr.ScVal, error) { return stellarx.ScBytes(b) } }
func scI128(v *big.Int) scValFunc { return func() (xdr.ScVal, error) { return stellarx.ScI128(v) } }
func scU64(v uint64) scValFunc    { return func() (xdr.ScVal, error) { return stellarx.ScUint64(v) } }

func scArgs(fns ...scValFunc) ([]xdr.ScVal, error) {
	out := make([]xdr.ScVal, len(fns))
	for i, fn := range fns {
		v, err := fn()
		if err != nil {
			return nil, err
		}
		out[i] = v
	}
	return out, nil
}

func mapRepoErr(err error) error {
	if errors.Is(err, ErrNotFoundInRepo) {
		return errNotFound
	}
	return err
}

var (
	errInsufficientBalance = errors.New(ErrInsufficientBalance)
	errAlreadyActive       = errors.New(ErrAlreadyActive)
	errInvalidReceiver     = errors.New(ErrInvalidReceiver)
	errReceiverNoTrustline = errors.New(ErrReceiverNoTrustline)
	errSenderNoTrustline   = errors.New(ErrSenderNoTrustline)
	errSelfTransfer        = errors.New(ErrSelfTransfer)
	errRequestUsed         = errors.New(ErrRequestUsed)
	errInvalidRequestID    = errors.New(ErrInvalidRequestID)
	errInvalidAmount       = errors.New(ErrInvalidAmount)
	errExpired             = errors.New(ErrExpired)
	errTerminalState       = errors.New(ErrTerminalState)
	errNotFound            = errors.New(ErrNotFound)
	errBadRequest          = errors.New(ErrBadRequest)
	errChainUnavailable    = errors.New(ErrChainUnavailable)
	errAccountNotFunded    = errors.New(ErrAccountNotFunded)
	errSimulationFailed    = errors.New(ErrSimulationFailed)
	errNotFunded           = errors.New(ErrNotFunded)
	errAlreadyClaimed      = errors.New(ErrAlreadyClaimed)
)

// requestIDPattern bounds the receiver-chosen request id: it is stored and
// echoed back in /sync, so it must not be free-form text. Empty is allowed
// (a plain cheque with no payment request behind it).
var requestIDPattern = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

func validRequestID(id string) bool {
	return id == "" || requestIDPattern.MatchString(id)
}
