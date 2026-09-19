package auth

import (
	"context"

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
