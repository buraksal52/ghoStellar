// Package tx implements pay-tx-service — the single place in the whole
// backend allowed to hand a signed XDR to the network
// (docs/reference/platform/architecture.md §4 rule 3). Every money-moving
// POST here requires an Idempotency-Key (§10); the same key submitted twice
// returns the first attempt's result rather than submitting again.
package tx

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/ports"
)

var ErrDBNotReadyErr = errors.New(ErrDBNotReady)

type Service struct {
	repos func() (txRepo, error)
	chain ports.ChainGateway
}

func NewService(pool *dbx.Pool, chain ports.ChainGateway) *Service {
	return &Service{chain: chain, repos: func() (txRepo, error) {
		p := pool.Get()
		if p == nil {
			return nil, ErrDBNotReadyErr
		}
		return NewRepository(p), nil
	}}
}

// newServiceWithRepo is the test seam: the same Service, wired to a
// caller-supplied repo instead of a *dbx.Pool.
func newServiceWithRepo(repo txRepo, chain ports.ChainGateway) *Service {
	return &Service{chain: chain, repos: func() (txRepo, error) { return repo, nil }}
}

// SubmitRequest is one call to Submit.
type SubmitRequest struct {
	IdempotencyKey string
	StellarAddress string // from the caller's bearer JWT, never client-supplied
	Purpose        string
	Kind           Kind
	SignedXDR      string
}

// SubmitResponse is what every caller — cheque, pool, anchor withdraw — gets
// back, keyed by the same envelope shape regardless of Kind.
type SubmitResponse struct {
	Hash       string `json:"hash"`
	Successful bool   `json:"successful"`
	ResultCode string `json:"resultCode,omitempty"`
	Replayed   bool   `json:"replayed"` // true if this is a cached result from an earlier call with the same key
}

// Submit forwards a signed XDR to pay-chain-gateway exactly once per
// IdempotencyKey. A repeat call with the same key returns the original
// result (D3) instead of submitting again.
func (s *Service) Submit(ctx context.Context, req SubmitRequest) (SubmitResponse, error) {
	repo, err := s.repos()
	if err != nil {
		return SubmitResponse{}, err
	}

	if cached, done, err := repo.GetIdempotentResponse(ctx, req.IdempotencyKey); err != nil {
		return SubmitResponse{}, fmt.Errorf("tx: check idempotency: %w", err)
	} else if done {
		var resp SubmitResponse
		if err := json.Unmarshal(cached, &resp); err != nil {
			return SubmitResponse{}, fmt.Errorf("tx: decode cached response: %w", err)
		}
		resp.Replayed = true
		return resp, nil
	}

	if err := repo.BeginSubmission(ctx, Submission{
		IdempotencyKey: req.IdempotencyKey,
		StellarAddress: req.StellarAddress,
		Purpose:        req.Purpose,
	}); err != nil {
		if errors.Is(err, ErrKeyInFlight) {
			return SubmitResponse{}, errKeyInFlight
		}
		return SubmitResponse{}, fmt.Errorf("tx: begin submission: %w", err)
	}

	var result ports.SubmitResult
	var submitErr error
	switch req.Kind {
	case KindSoroban:
		result, submitErr = s.chain.SubmitSoroban(ctx, req.SignedXDR)
	default:
		result, submitErr = s.chain.SubmitClassic(ctx, req.SignedXDR)
	}

	if submitErr != nil {
		// This is pay-chain-gateway/Horizon/Soroban itself being unreachable
		// or erroring — never the network's own verdict on the transaction.
		// Caching it as the key's permanent, replayable "done" result would
		// mean every retry (notably the offline-payment queue's 15s loop)
		// gets this SAME transient failure back forever via
		// GetIdempotentResponse, even long after the outage clears. Release
		// the key instead so a retry with the same Idempotency-Key starts a
		// genuinely fresh attempt (SERVICE.md #14/#23).
		resultCode := submitErr.Error()
		if err := repo.ReleaseSubmission(ctx, req.IdempotencyKey, resultCode); err != nil {
			return SubmitResponse{}, fmt.Errorf("tx: release submission: %w", err)
		}
		_ = repo.InsertAudit(ctx, req.StellarAddress, "tx.submission_failed", map[string]any{
			"idempotencyKey": req.IdempotencyKey, "purpose": req.Purpose, "kind": req.Kind, "resultCode": resultCode,
		})
		return SubmitResponse{}, fmt.Errorf("%s: %w", ErrSubmitFailed, submitErr)
	}

	// A genuine verdict from the network — successful or a real rejection —
	// is exactly what D3's idempotency cache exists to make replay-safe.
	state := "failed"
	resultCode := result.ResultCode
	if result.Successful {
		state = "success"
	} else if resultCode == "PENDING" {
		state = "submitted"
	}

	resp := SubmitResponse{Hash: result.Hash, Successful: result.Successful, ResultCode: resultCode}
	respJSON, _ := json.Marshal(resp)
	if err := repo.CompleteSubmission(ctx, req.IdempotencyKey, result.Hash, state, resultCode, respJSON); err != nil {
		return SubmitResponse{}, fmt.Errorf("tx: complete submission: %w", err)
	}
	// Best-effort (SERVICE.md #11): an audit write failure must never turn
	// a completed submission into a reported failure.
	_ = repo.InsertAudit(ctx, req.StellarAddress, "tx.submission_completed", map[string]any{
		"idempotencyKey": req.IdempotencyKey, "purpose": req.Purpose, "kind": req.Kind,
		"hash": result.Hash, "state": state, "resultCode": resultCode,
	})
	return resp, nil
}

func (s *Service) GetSubmission(ctx context.Context, key string) (Submission, error) {
	repo, err := s.repos()
	if err != nil {
		return Submission{}, err
	}
	sub, err := repo.GetSubmission(ctx, key)
	if errors.Is(err, ErrNotFoundInRepo) {
		return Submission{}, errNotFound
	}
	return sub, err
}

// ReapExpiredKeys deletes idempotency keys stuck in 'pending' past their
// expiry (SERVICE.md #14) — see Repository.ReapExpiredPendingKeys's doc
// comment for why deletion, not a status update, is the right recovery.
// Called on a ticker from cmd/txsvc/main.go; safe to call concurrently
// with ordinary Submit traffic since it only ever touches rows already
// past expires_at.
func (s *Service) ReapExpiredKeys(ctx context.Context) (int64, error) {
	repo, err := s.repos()
	if err != nil {
		return 0, err
	}
	return repo.ReapExpiredPendingKeys(ctx, time.Now())
}

var (
	errKeyInFlight = errors.New(ErrDuplicateIdempotencyKey)
	errNotFound    = errors.New(ErrNotFound)
)
