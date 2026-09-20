package cheque

import (
	"context"
	"time"
)

// chequeRepo is the DB surface Service actually uses. *Repository (pgx) is
// the production implementation; tests supply an in-memory fake — this
// interface is what makes Service unit-testable without a live Postgres.
type chequeRepo interface {
	CreateReservedCheque(ctx context.Context, c Cheque) error
	GetCheque(ctx context.Context, id string) (Cheque, error)
	SetPreauthEntry(ctx context.Context, id, entryXDR string) error
	SetLockTxHash(ctx context.Context, id, txHash string) error
	Transition(ctx context.Context, id string, from, to State, cause, txHash string) error
	ListActiveForAddress(ctx context.Context, address string) ([]Cheque, error)
	ExpiredFundedCheques(ctx context.Context, asOf time.Time) ([]Cheque, error)
	GetPool(ctx context.Context, owner string) (PoolDeposit, bool, error)
	RecordDeposit(ctx context.Context, owner, amountRaw string, decimals uint8, ledgerSeq int64) error
	RecordWithdraw(ctx context.Context, owner, amountRaw string) error
	// SetPoolAmount overwrites the cache's amount_raw/decimals with a
	// chain-derived value (Sync's self-heal — see reconcilePoolWithChain).
	// Unlike RecordDeposit/RecordWithdraw this is an authoritative
	// overwrite, not a delta.
	SetPoolAmount(ctx context.Context, owner, amountRaw string, decimals uint8) error
	InsertAudit(ctx context.Context, actor, action string, details any) error
}

var _ chequeRepo = (*Repository)(nil)
