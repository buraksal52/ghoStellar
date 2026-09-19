package auth

import "context"

// authRepo is the DB surface Service actually uses. *Repository (pgx) is
// the production implementation; tests supply an in-memory fake.
type authRepo interface {
	UpsertUser(ctx context.Context, address string) (User, error)
	GetUserByAddress(ctx context.Context, address string) (User, error)
}

var _ authRepo = (*Repository)(nil)
