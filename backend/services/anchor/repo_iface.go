package anchor

import "context"

// anchorRepo is the DB surface Service actually uses. *Repository (pgx) is
// the production implementation; tests supply an in-memory fake.
type anchorRepo interface {
	UpsertTransaction(ctx context.Context, t Transaction) error
	CreateTransaction(ctx context.Context, t Transaction) error
	UpdateTransaction(ctx context.Context, t Transaction) error
	ListForAddress(ctx context.Context, address string) ([]Transaction, error)
	SetTrustline(ctx context.Context, address, assetCode, assetIssuer, state string, ledgerSeq int64) error
}

var _ anchorRepo = (*Repository)(nil)
