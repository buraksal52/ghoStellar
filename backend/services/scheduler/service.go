package scheduler

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/oklog/ulid/v2"
	"github.com/stellar/go-stellar-sdk/keypair"

	"github.com/local-payment/backend/pkg/stellarx"
	"github.com/local-payment/backend/ports"
)

// backoffBase/backoffCap/deadLetterThreshold tune SweepExpiredCheques's
// per-cheque retry backoff (SERVICE.md #15): without this, a cheque that
// fails every sweep (e.g. a permanently underfunded keeper, or a
// malformed record) gets retried every SWEEP_INTERVAL_SECONDS forever,
// which is both wasted work and noisy logs indistinguishable from a fresh
// failure. State is in-memory only and resets on restart — acceptable for
// this MVP's tone (matches the rest of the codebase's "best-effort,
// bounded" scheduler jobs).
const (
	backoffBase         = time.Minute
	backoffCap          = time.Hour
	deadLetterThreshold = 10
)

type sweepFailure struct {
	count       int
	nextAttempt time.Time
}

// Config configures Service. KeeperSeed is a "S..." secret — the ONLY
// private key pay-scheduler-service holds. It pays the network fee for
// permissionless refund() calls and never authorizes moving a user's own
// funds: refund's contract-level check is that the CHEQUE has expired, not
// who submitted the call — see contracts/soroban/pay-escrow/README.md and
// docs/reference/platform/anchor-entegrasyonu.md's "Keeper hesabı" note.
// This is a fee-payer/relayer key, not a custodial key.
type Config struct {
	EscrowContractID  string
	NetworkPassphrase string
	KeeperSeed        string
}

type Service struct {
	cfg    Config
	chain  ports.ChainGateway
	cheque chequeGateway
	keeper *keypair.Full
	log    *slog.Logger

	failuresMu sync.Mutex
	failures   map[string]sweepFailure
}

// chequeGateway is the sweep's only dependency on pay-cheque-service —
// satisfied by *ChequeClient (HTTP, microservice profile) or, in a
// monolith process, ports/directadapter's in-process implementation.
type chequeGateway interface {
	ExpiredFundedCheques(ctx context.Context) ([]ExpiredCheque, error)
	MarkRefunded(ctx context.Context, chequeID, txHash string) error
}

var _ chequeGateway = (*ChequeClient)(nil)

func NewService(cfg Config, chain ports.ChainGateway, cheque chequeGateway, log *slog.Logger) (*Service, error) {
	keeper, err := keypair.ParseFull(cfg.KeeperSeed)
	if err != nil {
		return nil, fmt.Errorf("scheduler: parse keeper seed: %w", err)
	}
	return &Service{cfg: cfg, chain: chain, cheque: cheque, keeper: keeper, log: log, failures: map[string]sweepFailure{}}, nil
}

// SweepExpiredCheques refunds every expired, never-claimed cheque it can
// (p2p doc §6.2, §9.B1). A failure on one cheque is logged and does not
// stop the sweep from trying the rest. A cheque that keeps failing backs
// off exponentially instead of being retried every single sweep tick
// (SERVICE.md #15) — see backoffBase/backoffCap/deadLetterThreshold.
func (s *Service) SweepExpiredCheques(ctx context.Context) {
	expired, err := s.cheque.ExpiredFundedCheques(ctx)
	if err != nil {
		s.log.Error("sweep: fetch expired cheques failed", "error", err)
		return
	}
	if len(expired) == 0 {
		return
	}
	s.log.Info("sweep: refunding expired cheques", "count", len(expired))

	now := time.Now()
	for _, c := range expired {
		if s.inBackoff(c.ID, now) {
			continue
		}
		if err := s.refundOne(ctx, c); err != nil {
			s.recordFailure(c.ID, err)
			continue
		}
		s.clearFailure(c.ID)
	}
}

// inBackoff reports whether chequeID's next retry is still in the future.
func (s *Service) inBackoff(chequeID string, now time.Time) bool {
	s.failuresMu.Lock()
	defer s.failuresMu.Unlock()
	f, ok := s.failures[chequeID]
	return ok && now.Before(f.nextAttempt)
}

func (s *Service) recordFailure(chequeID string, err error) {
	s.failuresMu.Lock()
	f := s.failures[chequeID]
	f.count++
	delay := min(backoffBase<<uint(min(f.count-1, 6)), backoffCap) // 1m,2m,4m,8m,16m,32m,64m→capped
	f.nextAttempt = time.Now().Add(delay)
	s.failures[chequeID] = f
	count := f.count
	s.failuresMu.Unlock()

	if count >= deadLetterThreshold {
		s.log.Error("sweep: dead-lettered — repeated refund failures, needs manual attention",
			"cheque_id", chequeID, "failure_count", count, "error", err)
		return
	}
	s.log.Error("sweep: refund failed, backing off", "cheque_id", chequeID, "failure_count", count, "next_attempt", f.nextAttempt, "error", err)
}

func (s *Service) clearFailure(chequeID string) {
	s.failuresMu.Lock()
	delete(s.failures, chequeID)
	s.failuresMu.Unlock()
}

func (s *Service) refundOne(ctx context.Context, c ExpiredCheque) error {
	keeperAccount, err := s.chain.GetAccount(ctx, s.keeper.Address())
	if err != nil {
		return fmt.Errorf("get keeper account: %w", err)
	}
	if !keeperAccount.Exists {
		return fmt.Errorf("keeper account %s does not exist on-chain (needs funding)", s.keeper.Address())
	}

	idBytes, err := decodeULID(c.ID)
	if err != nil {
		return err
	}
	chequeIDArg, err := stellarx.ScBytes(idBytes)
	if err != nil {
		return err
	}
	op, err := stellarx.InvokeContract(s.cfg.EscrowContractID, s.keeper.Address(), "refund", chequeIDArg)
	if err != nil {
		return fmt.Errorf("build refund op: %w", err)
	}

	simulator := func(ctx context.Context, unsignedXDR string) (stellarx.SimulationResult, error) {
		res, err := s.chain.SimulateTransaction(ctx, unsignedXDR)
		if err != nil {
			return stellarx.SimulationResult{}, err
		}
		if !res.Success {
			return stellarx.SimulationResult{}, fmt.Errorf("simulation failed: %s", res.Error)
		}
		return stellarx.SimulationResult{TransactionDataXDR: res.TransactionDataXDR, AuthXDR: res.AuthXDR}, nil
	}
	unsignedXDR, err := stellarx.AssembleInvocation(ctx, simulator, s.cfg.NetworkPassphrase, s.keeper.Address(), keeperAccount.Sequence, op)
	if err != nil {
		return fmt.Errorf("assemble refund tx: %w", err)
	}

	signedXDR, err := stellarx.SignTransactionXDR(unsignedXDR, s.cfg.NetworkPassphrase, s.keeper)
	if err != nil {
		return fmt.Errorf("sign refund tx: %w", err)
	}

	result, err := s.chain.SubmitSoroban(ctx, signedXDR)
	if err != nil {
		return fmt.Errorf("submit refund tx: %w", err)
	}
	if !result.Successful {
		return fmt.Errorf("refund tx did not succeed: %s", result.ResultCode)
	}

	if err := s.cheque.MarkRefunded(ctx, c.ID, result.Hash); err != nil {
		return fmt.Errorf("mark refunded: %w", err)
	}
	s.log.Info("sweep: refunded", "cheque_id", c.ID, "tx_hash", result.Hash)
	return nil
}

// BumpEscrowInstance keeps pay-escrow's own instance storage alive — a
// housekeeping call with no auth requirement, paid for by the keeper.
func (s *Service) BumpEscrowInstance(ctx context.Context) error {
	keeperAccount, err := s.chain.GetAccount(ctx, s.keeper.Address())
	if err != nil {
		return fmt.Errorf("get keeper account: %w", err)
	}
	op, err := stellarx.InvokeContract(s.cfg.EscrowContractID, s.keeper.Address(), "bump_instance")
	if err != nil {
		return err
	}
	simulator := func(ctx context.Context, unsignedXDR string) (stellarx.SimulationResult, error) {
		res, err := s.chain.SimulateTransaction(ctx, unsignedXDR)
		if err != nil {
			return stellarx.SimulationResult{}, err
		}
		return stellarx.SimulationResult{TransactionDataXDR: res.TransactionDataXDR, AuthXDR: res.AuthXDR}, nil
	}
	unsignedXDR, err := stellarx.AssembleInvocation(ctx, simulator, s.cfg.NetworkPassphrase, s.keeper.Address(), keeperAccount.Sequence, op)
	if err != nil {
		return fmt.Errorf("assemble bump tx: %w", err)
	}
	signedXDR, err := stellarx.SignTransactionXDR(unsignedXDR, s.cfg.NetworkPassphrase, s.keeper)
	if err != nil {
		return err
	}
	_, err = s.chain.SubmitSoroban(ctx, signedXDR)
	return err
}

func decodeULID(s string) ([]byte, error) {
	id, err := ulid.ParseStrict(s)
	if err != nil {
		return nil, fmt.Errorf("scheduler: bad cheque id %q: %w", s, err)
	}
	return id[:], nil
}
