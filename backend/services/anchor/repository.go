package anchor

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Repository struct {
	pool *pgxpool.Pool
}

func NewRepository(pool *pgxpool.Pool) *Repository {
	return &Repository{pool: pool}
}

var ErrNotFoundInRepo = errors.New("anchor: not found")

func (r *Repository) UpsertTransaction(ctx context.Context, t Transaction) error {
	command, err := r.pool.Exec(ctx, `
		INSERT INTO pay.anchor_transactions (id, anchor_id, stellar_address, kind, state, amount_raw, decimals, stellar_tx_hash)
		VALUES ($1, $2, $3, $4, $5, NULLIF($6, '')::numeric, NULLIF($7, 0), NULLIF($8, ''))
		ON CONFLICT (id) DO UPDATE SET
			state = EXCLUDED.state,
			amount_raw = coalesce(EXCLUDED.amount_raw, pay.anchor_transactions.amount_raw),
			decimals = coalesce(EXCLUDED.decimals, pay.anchor_transactions.decimals),
			stellar_tx_hash = coalesce(EXCLUDED.stellar_tx_hash, pay.anchor_transactions.stellar_tx_hash),
			updated_at = now()
		WHERE pay.anchor_transactions.stellar_address = EXCLUDED.stellar_address
		  AND pay.anchor_transactions.anchor_id = EXCLUDED.anchor_id
	`, t.ID, t.AnchorID, t.StellarAddress, t.Kind, t.State, t.AmountRaw, t.Decimals, t.StellarTxHash)
	if err == nil && command.RowsAffected() == 0 {
		return ErrNotFoundInRepo
	}
	return err
}

func (r *Repository) CreateTransaction(ctx context.Context, t Transaction) error {
	command, err := r.pool.Exec(ctx, `
		INSERT INTO pay.anchor_transactions (id, anchor_id, stellar_address, kind, state)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (id) DO UPDATE SET id = EXCLUDED.id
		WHERE pay.anchor_transactions.stellar_address = EXCLUDED.stellar_address
		  AND pay.anchor_transactions.anchor_id = EXCLUDED.anchor_id
	`, t.ID, t.AnchorID, t.StellarAddress, t.Kind, t.State)
	if err == nil && command.RowsAffected() == 0 {
		return ErrNotFoundInRepo
	}
	return err
}

func (r *Repository) UpdateTransaction(ctx context.Context, t Transaction) error {
	command, err := r.pool.Exec(ctx, `
		UPDATE pay.anchor_transactions
		SET state = $4,
		    amount_raw = coalesce(NULLIF($5, '')::numeric, amount_raw),
		    decimals = coalesce(NULLIF($6, 0), decimals),
		    stellar_tx_hash = coalesce(NULLIF($7, ''), stellar_tx_hash),
		    updated_at = now()
		WHERE id = $1 AND anchor_id = $2 AND stellar_address = $3
	`, t.ID, t.AnchorID, t.StellarAddress, t.State, t.AmountRaw, t.Decimals, t.StellarTxHash)
	if err == nil && command.RowsAffected() == 0 {
		return ErrNotFoundInRepo
	}
	return err
}

func (r *Repository) ListForAddress(ctx context.Context, address string) ([]Transaction, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id, anchor_id, stellar_address, kind, state, coalesce(amount_raw::text,''), coalesce(decimals,0),
		       coalesce(stellar_tx_hash,''), started_at, updated_at
		FROM pay.anchor_transactions WHERE stellar_address = $1 ORDER BY started_at DESC
	`, address)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Transaction
	for rows.Next() {
		var t Transaction
		if err := rows.Scan(&t.ID, &t.AnchorID, &t.StellarAddress, &t.Kind, &t.State, &t.AmountRaw, &t.Decimals,
			&t.StellarTxHash, &t.StartedAt, &t.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (r *Repository) SetTrustline(ctx context.Context, address, assetCode, assetIssuer, state string, ledgerSeq int64) error {
	_, err := r.pool.Exec(ctx, `
		INSERT INTO pay.trustlines (stellar_address, asset_code, asset_issuer, state, ledger_seq)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (stellar_address, asset_code, asset_issuer) DO UPDATE SET
			state = EXCLUDED.state, ledger_seq = EXCLUDED.ledger_seq, updated_at = now()
	`, address, assetCode, assetIssuer, state, ledgerSeq)
	return err
}
