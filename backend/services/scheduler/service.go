package scheduler

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/oklog/ulid/v2"
	"github.com/stellar/go-stellar-sdk/keypair"

	"github.com/local-payment/backend/pkg/stellarx"
	"github.com/local-payment/backend/ports"
)

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
	cheque *ChequeClient
	keeper *keypair.Full
	log    *slog.Logger
}

func NewService(cfg Config, chain ports.ChainGateway, cheque *ChequeClient, log *slog.Logger) (*Service, error) {
	keeper, err := keypair.ParseFull(cfg.KeeperSeed)
	if err != nil {
		return nil, fmt.Errorf("scheduler: parse keeper seed: %w", err)
	}
	return &Service{cfg: cfg, chain: chain, cheque: cheque, keeper: keeper, log: log}, nil
}

// SweepExpiredCheques refunds every expired, never-claimed cheque it can
// (p2p doc §6.2, §9.B1). A failure on one cheque is logged and does not
// stop the sweep from trying the rest.
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

	for _, c := range expired {
		if err := s.refundOne(ctx, c); err != nil {
			s.log.Error("sweep: refund failed", "cheque_id", c.ID, "error", err)
			continue
		}
	}
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

	simulator := func(ctx context.Context, unsignedXDR string) (string, error) {
		res, err := s.chain.SimulateTransaction(ctx, unsignedXDR)
		if err != nil {
			return "", err
		}
		if !res.Success {
			return "", fmt.Errorf("simulation failed: %s", res.Error)
		}
		return res.TransactionDataXDR, nil
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
	simulator := func(ctx context.Context, unsignedXDR string) (string, error) {
		res, err := s.chain.SimulateTransaction(ctx, unsignedXDR)
		if err != nil {
			return "", err
		}
		return res.TransactionDataXDR, nil
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
