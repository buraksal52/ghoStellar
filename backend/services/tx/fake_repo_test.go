package tx

import (
	"context"
	"encoding/json"
	"time"
)

// fakeRepo is an in-memory txRepo double mirroring pay.idempotency_keys +
// pay.submissions closely enough to exercise Service's single-flight and
// replay logic without a real Postgres.
type fakeRepo struct {
	keyStatus   map[string]string // key -> "pending" | "done"
	keyResponse map[string]json.RawMessage
	submissions map[string]Submission

	failOn map[string]error
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{
		keyStatus:   map[string]string{},
		keyResponse: map[string]json.RawMessage{},
		submissions: map[string]Submission{},
		failOn:      map[string]error{},
	}
}

func (f *fakeRepo) GetIdempotentResponse(ctx context.Context, key string) ([]byte, bool, error) {
	if err := f.failOn["GetIdempotentResponse"]; err != nil {
		return nil, false, err
	}
	status, ok := f.keyStatus[key]
	if !ok {
		return nil, false, nil
	}
	return f.keyResponse[key], status == "done", nil
}

func (f *fakeRepo) BeginSubmission(ctx context.Context, s Submission) error {
	if err := f.failOn["BeginSubmission"]; err != nil {
		return err
	}
	if _, exists := f.keyStatus[s.IdempotencyKey]; exists {
		return ErrKeyInFlight
	}
	f.keyStatus[s.IdempotencyKey] = "pending"
	s.State = "pending"
	s.CreatedAt = time.Now()
	s.UpdatedAt = time.Now()
	f.submissions[s.IdempotencyKey] = s
	return nil
}

func (f *fakeRepo) CompleteSubmission(ctx context.Context, key, txHash, state, resultCode string, responseJSON []byte) error {
	if err := f.failOn["CompleteSubmission"]; err != nil {
		return err
	}
	sub := f.submissions[key]
	sub.TxHash = txHash
	sub.State = state
	sub.ResultCode = resultCode
	sub.UpdatedAt = time.Now()
	f.submissions[key] = sub
	f.keyStatus[key] = "done"
	f.keyResponse[key] = responseJSON
	return nil
}

func (f *fakeRepo) GetSubmission(ctx context.Context, key string) (Submission, error) {
	if err := f.failOn["GetSubmission"]; err != nil {
		return Submission{}, err
	}
	sub, ok := f.submissions[key]
	if !ok {
		return Submission{}, ErrNotFoundInRepo
	}
	return sub, nil
}
