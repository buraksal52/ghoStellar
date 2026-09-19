package tx

import "context"

// txRepo is the DB surface Service actually uses. *Repository (pgx) is the
// production implementation; tests supply an in-memory fake.
type txRepo interface {
	GetIdempotentResponse(ctx context.Context, key string) (json []byte, done bool, err error)
	BeginSubmission(ctx context.Context, s Submission) error
	CompleteSubmission(ctx context.Context, key, txHash, state, resultCode string, responseJSON []byte) error
	GetSubmission(ctx context.Context, key string) (Submission, error)
}

var _ txRepo = (*Repository)(nil)
