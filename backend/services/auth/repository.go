package auth

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Repository holds only SQL (docs/reference/platform/architecture.md §13's
// file template) — no business rules.
type Repository struct {
	pool *pgxpool.Pool
}

func NewRepository(pool *pgxpool.Pool) *Repository {
	return &Repository{pool: pool}
}

// UpsertUser creates the user row on first successful SEP-10 login, or
// returns the existing one. Identity is the address; nothing else is
// required to "register".
func (r *Repository) UpsertUser(ctx context.Context, address string) (User, error) {
	var u User
	err := r.pool.QueryRow(ctx, `
		INSERT INTO pay.users (stellar_address)
		VALUES ($1)
		ON CONFLICT (stellar_address) DO UPDATE SET stellar_address = EXCLUDED.stellar_address
		RETURNING id, stellar_address, coalesce(display_name, ''), created_at
	`, address).Scan(&u.ID, &u.StellarAddress, &u.DisplayName, &u.CreatedAt)
	return u, err
}

func (r *Repository) GetUserByAddress(ctx context.Context, address string) (User, error) {
	var u User
	err := r.pool.QueryRow(ctx, `
		SELECT id, stellar_address, coalesce(display_name, ''), created_at
		FROM pay.users WHERE stellar_address = $1
	`, address).Scan(&u.ID, &u.StellarAddress, &u.DisplayName, &u.CreatedAt)
	return u, err
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
