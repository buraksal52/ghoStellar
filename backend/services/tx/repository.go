package tx

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Repository holds only SQL (architecture.md §13's file template).
type Repository struct {
	pool *pgxpool.Pool
}

func NewRepository(pool *pgxpool.Pool) *Repository {
	return &Repository{pool: pool}
}

// ErrKeyInFlight means a submission with this idempotency key already
// exists and has not finished yet — the caller should not submit again
// (D3/D5-style single-flight, not a hard duplicate rejection: the FIRST
// caller's result is what eventually satisfies both).
var ErrKeyInFlight = errors.New("tx: idempotency key already in flight")

// BeginSubmission atomically claims idempotencyKey: it succeeds once per
// key. A second concurrent call with the same key gets ErrKeyInFlight
// instead of double-submitting (B2: safe re-query, never a duplicate send).
func (r *Repository) BeginSubmission(ctx context.Context, s Submission) error {
	_, err := r.pool.Exec(ctx, `
		INSERT INTO pay.idempotency_keys (key, stellar_address, request_hash, status)
		VALUES ($1, $2, $3, 'pending')
	`, s.IdempotencyKey, s.StellarAddress, s.Purpose)
	if err != nil {
		return ErrKeyInFlight
	}
	_, err = r.pool.Exec(ctx, `
		INSERT INTO pay.submissions (idempotency_key, stellar_address, purpose, state)
		VALUES ($1, $2, $3, 'pending')
	`, s.IdempotencyKey, s.StellarAddress, s.Purpose)
	return err
}

func (r *Repository) CompleteSubmission(ctx context.Context, key, txHash, state, resultCode string, responseJSON []byte) error {
	_, err := r.pool.Exec(ctx, `
		UPDATE pay.submissions
		SET tx_hash = $2, state = $3, result_code = $4, updated_at = now()
		WHERE idempotency_key = $1
	`, key, txHash, state, resultCode)
	if err != nil {
		return err
	}
	_, err = r.pool.Exec(ctx, `
		UPDATE pay.idempotency_keys SET status = 'done', response_json = $2 WHERE key = $1
	`, key, responseJSON)
	return err
}

// ReleaseSubmission undoes BeginSubmission's claim when the chain gateway
// itself could not be reached (a network/RPC failure — the caller never got
// the network's actual verdict), rather than caching that failure as the
// key's permanent, replayable result. That used to be indistinguishable
// from a genuine chain rejection: every retry (e.g. the offline-payment
// queue's 15s loop) got the SAME cached failure back forever via
// GetIdempotentResponse, even once the transient problem cleared. Deleting
// the pending idempotency_keys row lets a retry with the SAME key start a
// genuinely fresh BeginSubmission; pay.submissions is updated to 'failed'
// as the historical record of the attempt but is never looked up by key on
// the read path, so leaving it behind does not resurrect the cached result.
func (r *Repository) ReleaseSubmission(ctx context.Context, key, resultCode string) error {
	_, err := r.pool.Exec(ctx, `
		UPDATE pay.submissions SET state = 'failed', result_code = $2, updated_at = now()
		WHERE idempotency_key = $1
	`, key, resultCode)
	if err != nil {
		return err
	}
	_, err = r.pool.Exec(ctx, `
		DELETE FROM pay.idempotency_keys WHERE key = $1 AND status = 'pending'
	`, key)
	return err
}

func (r *Repository) GetSubmission(ctx context.Context, key string) (Submission, error) {
	var s Submission
	err := r.pool.QueryRow(ctx, `
		SELECT idempotency_key, stellar_address, purpose, coalesce(tx_hash,''), state, coalesce(result_code,''), created_at, updated_at
		FROM pay.submissions WHERE idempotency_key = $1
	`, key).Scan(&s.IdempotencyKey, &s.StellarAddress, &s.Purpose, &s.TxHash, &s.State, &s.ResultCode, &s.CreatedAt, &s.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Submission{}, ErrNotFoundInRepo
	}
	return s, err
}

// GetIdempotentResponse returns a previously stored response for key if the
// submission already completed — the D3 short-circuit for a retried
// request.
func (r *Repository) GetIdempotentResponse(ctx context.Context, key string) (json []byte, done bool, err error) {
	var status string
	err = r.pool.QueryRow(ctx, `
		SELECT status, response_json FROM pay.idempotency_keys WHERE key = $1
	`, key).Scan(&status, &json)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return json, status == "done", nil
}

// ErrNotFoundInRepo signals "no such row" up to Service, which maps it to
// tx.not_found.
var ErrNotFoundInRepo = errors.New("tx: not found")

// ReapExpiredPendingKeys deletes idempotency keys that have been stuck in
// 'pending' past their expires_at (SERVICE.md #14): if the process died
// mid-submission, BeginSubmission's INSERT would otherwise fail forever
// with ErrKeyInFlight for that key, permanently 409-ing a client's retry.
// Deleting the row (not marking it 'done') is deliberate — it lets a retry
// with the SAME Idempotency-Key start a genuinely fresh attempt via
// BeginSubmission's ordinary INSERT path, rather than requiring a synthetic
// cached response. pay.submissions is left untouched as the historical
// record of the original (stuck) attempt.
func (r *Repository) ReapExpiredPendingKeys(ctx context.Context, before time.Time) (int64, error) {
	cmdTag, err := r.pool.Exec(ctx, `
		DELETE FROM pay.idempotency_keys WHERE status = 'pending' AND expires_at < $1
	`, before)
	if err != nil {
		return 0, err
	}
	return cmdTag.RowsAffected(), nil
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
