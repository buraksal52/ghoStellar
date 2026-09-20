package cheque

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Repository holds only SQL (architecture.md §13's file template).
type Repository struct {
	pool *pgxpool.Pool
}

func NewRepository(pool *pgxpool.Pool) *Repository {
	return &Repository{pool: pool}
}

var (
	// ErrAlreadyActiveInRepo surfaces the uq_reservations_active_account
	// violation (D5/A3) to Service without leaking a pgx/postgres error type.
	ErrAlreadyActiveInRepo = errors.New("cheque: sender already has an active cheque")
	ErrNotFoundInRepo      = errors.New("cheque: not found")
	// ErrRequestUsedInRepo surfaces uq_cheques_receiver_request (migration
	// 000003): a cheque for this (receiver, requestId) already exists.
	ErrRequestUsedInRepo   = errors.New("cheque: payment request already used")
	ErrBadTransitionInRepo = errors.New("cheque: transition already recorded or invalid")
)

// CreateReservedCheque inserts the cheque row (state IMZALI_REZERVE) and its
// reservation atomically. The partial unique index on active reservations
// (migration 000001) is what actually enforces D5/A3 — a concurrent second
// attempt for the same sender fails here with ErrAlreadyActiveInRepo, not
// via an application-level race.
func (r *Repository) CreateReservedCheque(ctx context.Context, c Cheque) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	_, err = tx.Exec(ctx, `
		INSERT INTO pay.cheques (id, sender_address, receiver_address, token_contract, amount_raw, decimals, state, expires_at, request_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NULLIF($9, ''))
	`, c.ID, c.SenderAddress, c.ReceiverAddress, c.TokenContract, c.AmountRaw, c.Decimals, c.State, c.ExpiresAt, c.RequestID)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" && pgErr.ConstraintName == "uq_cheques_receiver_request" {
			return ErrRequestUsedInRepo
		}
		return err
	}

	_, err = tx.Exec(ctx, `
		INSERT INTO pay.reservations (cheque_id, account, amount_raw, state)
		VALUES ($1, $2, $3, 'active')
	`, c.ID, c.SenderAddress, c.AmountRaw)
	if err != nil {
		return ErrAlreadyActiveInRepo
	}

	_, err = tx.Exec(ctx, `
		INSERT INTO pay.cheque_transitions (cheque_id, from_state, to_state, cause)
		VALUES ($1, $2, $3, 'user_action')
	`, c.ID, StateTaslak, StateImzaliRezerve)
	if err != nil {
		return err
	}

	return tx.Commit(ctx)
}

func (r *Repository) GetCheque(ctx context.Context, id string) (Cheque, error) {
	var c Cheque
	err := r.pool.QueryRow(ctx, `
		SELECT id, sender_address, receiver_address, token_contract, amount_raw::text, decimals,
		       state, expires_at, coalesce(lock_tx_hash,''), coalesce(preauth_entry_xdr,''), created_at, updated_at,
		       coalesce(request_id,'')
		FROM pay.cheques WHERE id = $1
	`, id).Scan(&c.ID, &c.SenderAddress, &c.ReceiverAddress, &c.TokenContract, &c.AmountRaw, &c.Decimals,
		&c.State, &c.ExpiresAt, &c.LockTxHash, &c.PreauthEntryXDR, &c.CreatedAt, &c.UpdatedAt, &c.RequestID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Cheque{}, ErrNotFoundInRepo
	}
	return c, err
}

// ActiveChequeForSender returns the sender's one allowed active reservation,
// if any (D5).
func (r *Repository) ActiveChequeForSender(ctx context.Context, sender string) (Cheque, bool, error) {
	var id string
	err := r.pool.QueryRow(ctx, `
		SELECT cheque_id FROM pay.reservations WHERE account = $1 AND state = 'active'
	`, sender).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return Cheque{}, false, nil
	}
	if err != nil {
		return Cheque{}, false, err
	}
	c, err := r.GetCheque(ctx, id)
	return c, true, err
}

// SetPreauthEntry stores the device-signed force_collect authorization
// entry (base64 XDR) so it can be handed to the receiver later.
func (r *Repository) SetPreauthEntry(ctx context.Context, id, entryXDR string) error {
	_, err := r.pool.Exec(ctx, `UPDATE pay.cheques SET preauth_entry_xdr = $2, updated_at = now() WHERE id = $1`, id, entryXDR)
	return err
}

func (r *Repository) SetLockTxHash(ctx context.Context, id, txHash string) error {
	_, err := r.pool.Exec(ctx, `UPDATE pay.cheques SET lock_tx_hash = $2, updated_at = now() WHERE id = $1`, id, txHash)
	return err
}

// Transition moves a cheque from `from` to `to`, recording it in
// cheque_transitions (whose UNIQUE(cheque_id, from_state, to_state)
// constraint is D3's idempotency guard — a replayed chain event or a
// double-submitted client action hits the constraint instead of applying
// the transition twice) and, unless to is a non-terminal intermediate
// state, releasing the sender's reservation.
func (r *Repository) Transition(ctx context.Context, id string, from, to State, cause, txHash string) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	cmdTag, err := tx.Exec(ctx, `
		UPDATE pay.cheques SET state = $2, updated_at = now()
		WHERE id = $1 AND state = $3
	`, id, to, from)
	if err != nil {
		return err
	}
	if cmdTag.RowsAffected() == 0 {
		return ErrBadTransitionInRepo
	}

	_, err = tx.Exec(ctx, `
		INSERT INTO pay.cheque_transitions (cheque_id, from_state, to_state, cause, tx_hash)
		VALUES ($1, $2, $3, $4, NULLIF($5, ''))
	`, id, from, to, cause, txHash)
	if err != nil {
		return ErrBadTransitionInRepo // UNIQUE violation: already recorded — D3, treat as a no-op success upstream
	}

	if to.IsTerminal() {
		if _, err := tx.Exec(ctx, `UPDATE pay.reservations SET state = 'released' WHERE cheque_id = $1`, id); err != nil {
			return err
		}
	}

	return tx.Commit(ctx)
}

// ListActiveForAddress returns every cheque where address is either party —
// active AND terminal, newest-updated first. This is /sync's only source of
// cheque history for the Activity feed (there is no separate history
// endpoint or local log for cheques, unlike pool events), so a terminal
// cheque (KAPANDI/IADE_EDILDI/HUKUMSUZ/KARSILIKSIZ) must still come back
// here — it used to be excluded, which made a completed send/receive
// disappear from both parties' history within seconds of AcknowledgeReceipt
// moving it to KAPANDI. `pendingClaimsProvider` on the client already
// filters this same list down to the three claimable states client-side, so
// returning terminal rows too doesn't affect that.
//
// Bounded by LIMIT rather than a time window: simpler, and 200 is already
// far more than the Activity feed shows at once.
func (r *Repository) ListActiveForAddress(ctx context.Context, address string) ([]Cheque, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id, sender_address, receiver_address, token_contract, amount_raw::text, decimals,
		       state, expires_at, coalesce(lock_tx_hash,''), coalesce(preauth_entry_xdr,''), created_at, updated_at,
		       coalesce(request_id,'')
		FROM pay.cheques
		WHERE (sender_address = $1 OR receiver_address = $1)
		ORDER BY updated_at DESC
		LIMIT 200
	`, address)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// Non-nil so an empty result serializes as [] rather than null — the
	// mobile client's generated parser casts /sync's "cheques" to a List.
	out := []Cheque{}
	for rows.Next() {
		var c Cheque
		if err := rows.Scan(&c.ID, &c.SenderAddress, &c.ReceiverAddress, &c.TokenContract, &c.AmountRaw, &c.Decimals,
			&c.State, &c.ExpiresAt, &c.LockTxHash, &c.PreauthEntryXDR, &c.CreatedAt, &c.UpdatedAt, &c.RequestID); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// ExpiredFundedCheques returns HAVUZDA cheques whose expiry has passed —
// what pay-scheduler-service sweeps into IADE_EDILEBILIR then submits a
// permissionless refund for.
func (r *Repository) ExpiredFundedCheques(ctx context.Context, asOf time.Time) ([]Cheque, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id, sender_address, receiver_address, token_contract, amount_raw::text, decimals,
		       state, expires_at, coalesce(lock_tx_hash,''), coalesce(preauth_entry_xdr,''), created_at, updated_at,
		       coalesce(request_id,'')
		FROM pay.cheques WHERE state = $1 AND expires_at <= $2
	`, StateHavuzda, asOf)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Cheque{}
	for rows.Next() {
		var c Cheque
		if err := rows.Scan(&c.ID, &c.SenderAddress, &c.ReceiverAddress, &c.TokenContract, &c.AmountRaw, &c.Decimals,
			&c.State, &c.ExpiresAt, &c.LockTxHash, &c.PreauthEntryXDR, &c.CreatedAt, &c.UpdatedAt, &c.RequestID); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// ---- Havuz (pool) ----------------------------------------------------

func (r *Repository) GetPool(ctx context.Context, owner string) (PoolDeposit, bool, error) {
	var p PoolDeposit
	p.OwnerAddress = owner
	var lastLedger *int64
	var lastDepositAt *time.Time
	err := r.pool.QueryRow(ctx, `
		SELECT amount_raw::text, decimals, last_deposit_ledger, last_deposit_at, updated_at
		FROM pay.pool_deposits WHERE owner_address = $1
	`, owner).Scan(&p.AmountRaw, &p.Decimals, &lastLedger, &lastDepositAt, &p.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return PoolDeposit{OwnerAddress: owner, AmountRaw: "0"}, false, nil
	}
	if err != nil {
		return PoolDeposit{}, false, err
	}
	if lastLedger != nil {
		p.LastDepositLedger = *lastLedger
	}
	if lastDepositAt != nil {
		p.LastDepositAt = *lastDepositAt
	}
	return p, true, nil
}

// RecordDeposit upserts the cache row after a deposit XDR has been
// confirmed on-chain (Confirm handler) — this row is the read-side cache
// /sync serves quickly. last_deposit_at and ledger are retained as deposit
// history metadata; they do not restrict withdrawals.
func (r *Repository) RecordDeposit(ctx context.Context, owner, amountRaw string, decimals uint8, ledgerSeq int64) error {
	_, err := r.pool.Exec(ctx, `
		INSERT INTO pay.pool_deposits (owner_address, amount_raw, decimals, last_deposit_ledger, last_deposit_at, ledger_seq)
		VALUES ($1, $2, $3, $4, now(), $4)
		ON CONFLICT (owner_address) DO UPDATE SET
			amount_raw = pay.pool_deposits.amount_raw + EXCLUDED.amount_raw,
			decimals = EXCLUDED.decimals,
			last_deposit_ledger = EXCLUDED.last_deposit_ledger,
			last_deposit_at = now(),
			ledger_seq = EXCLUDED.ledger_seq,
			updated_at = now()
	`, owner, amountRaw, decimals, ledgerSeq)
	return err
}

// RecordWithdraw debits the cache row. GREATEST(...,0) stops the cache from
// ever going negative on a double-recorded or out-of-order withdraw confirm
// — the contract is still the actual balance authority (D6), and Sync's
// reconcilePoolWithChain is what actually corrects a cache that has drifted
// from it; this only keeps a single UPDATE from producing a negative value
// in between. Unlike the old `amount_raw >= $2` guard, this always affects
// exactly one row (when the owner has one) so a caller can tell "no such
// pool row" apart from "cache already drifted low" via RowsAffected.
func (r *Repository) RecordWithdraw(ctx context.Context, owner, amountRaw string) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE pay.pool_deposits SET amount_raw = GREATEST(amount_raw - $2, 0), updated_at = now()
		WHERE owner_address = $1
	`, owner, amountRaw)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("%w: no pool row for owner", ErrNotFoundInRepo)
	}
	return nil
}

// SetPoolAmount overwrites the cache row with a chain-derived value (Sync's
// self-heal, see reconcilePoolWithChain) — an authoritative overwrite, not a
// delta like RecordDeposit/RecordWithdraw. Upserts because the contract may
// have a pool record for an owner whose cache row was never written (e.g.
// a deposit confirm that never landed).
func (r *Repository) SetPoolAmount(ctx context.Context, owner, amountRaw string, decimals uint8) error {
	_, err := r.pool.Exec(ctx, `
		INSERT INTO pay.pool_deposits (owner_address, amount_raw, decimals, ledger_seq)
		VALUES ($1, $2, $3, 0)
		ON CONFLICT (owner_address) DO UPDATE SET
			amount_raw = EXCLUDED.amount_raw,
			decimals = EXCLUDED.decimals,
			updated_at = now()
	`, owner, amountRaw, decimals)
	return err
}

// InsertAudit appends one row to the shared pay.audit_log table
// (SERVICE.md #11). Multiple services write to this table — that is not
// the "a service reads another service's table" violation CLAUDE.md's
// GOTCHA warns against (this repo never SELECTs from audit_log, only
// INSERTs), it is the intended append-only, multi-writer audit trail
// architecture.md promises.
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
