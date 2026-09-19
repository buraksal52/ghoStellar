package anchor

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"
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

// GetTrustlineState reads back what SetTrustline last recorded for
// (address, assetCode, assetIssuer). Closes SERVICE.md #11's other half:
// until now pay.trustlines was write-only (SetTrustline had no reader
// anywhere). Service.startInteractive uses this as its OWN service's fast
// pre-check before starting a SEP-24 session — anchor-service reading a
// table it itself owns and writes, never another service's table.
func (r *Repository) GetTrustlineState(ctx context.Context, address, assetCode, assetIssuer string) (state string, found bool, err error) {
	err = r.pool.QueryRow(ctx, `
		SELECT state FROM pay.trustlines WHERE stellar_address = $1 AND asset_code = $2 AND asset_issuer = $3
	`, address, assetCode, assetIssuer).Scan(&state)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return state, true, nil
}

// InsertAudit appends one row to the shared pay.audit_log table
// (SERVICE.md #11) — see cheque.Repository.InsertAudit's doc comment for
// why multiple services writing to this one append-only table does not
// violate the "no service reads another's table" rule.
func (r *Repository) InsertAudit(ctx context.Context, actor, action string, details any) error {
	detailsJSON, err := json.Marshal(details)
	if err != nil {
		return err
	}
	_, err = r.pool.Exec(ctx, `
		INSERT INTO pay.audit_log (actor, action, details) VALUES ($1, $2, $3)
	`, actor, action, detailsJSON)
	return err
}
