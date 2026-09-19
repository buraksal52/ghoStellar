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

	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/ports"
)

var ErrDBNotReadyErr = errors.New(ErrDBNotReady)

type Service struct {
	pool  *dbx.Pool
	chain ports.ChainGateway
}

func NewService(pool *dbx.Pool, chain ports.ChainGateway) *Service {
	return &Service{pool: pool, chain: chain}
}

func (s *Service) repo() (*Repository, error) {
	p := s.pool.Get()
	if p == nil {
		return nil, ErrDBNotReadyErr
	}
	return NewRepository(p), nil
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
	repo, err := s.repo()
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

	state := "failed"
	resultCode := ""
	if submitErr == nil {
		resultCode = result.ResultCode
		if result.Successful {
			state = "success"
		} else if resultCode == "PENDING" {
			state = "submitted"
		}
	} else {
		resultCode = submitErr.Error()
	}

	resp := SubmitResponse{Hash: result.Hash, Successful: result.Successful, ResultCode: resultCode}
	respJSON, _ := json.Marshal(resp)
	if err := repo.CompleteSubmission(ctx, req.IdempotencyKey, result.Hash, state, resultCode, respJSON); err != nil {
		return SubmitResponse{}, fmt.Errorf("tx: complete submission: %w", err)
	}
	if submitErr != nil {
		return SubmitResponse{}, fmt.Errorf("%s: %w", ErrSubmitFailed, submitErr)
	}
	return resp, nil
}

func (s *Service) GetSubmission(ctx context.Context, key string) (Submission, error) {
	repo, err := s.repo()
	if err != nil {
		return Submission{}, err
	}
	sub, err := repo.GetSubmission(ctx, key)
	if errors.Is(err, ErrNotFoundInRepo) {
		return Submission{}, errNotFound
	}
	return sub, err
}

var (
	errKeyInFlight = errors.New(ErrDuplicateIdempotencyKey)
	errNotFound    = errors.New(ErrNotFound)
)
