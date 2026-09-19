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
	keyStatus    map[string]string // key -> "pending" | "done"
	keyResponse  map[string]json.RawMessage
	keyExpiresAt map[string]time.Time
	submissions  map[string]Submission
	auditLog     []auditEntry

	failOn map[string]error
}

type auditEntry struct {
	actor, action string
	details       any
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{
		keyStatus:    map[string]string{},
		keyResponse:  map[string]json.RawMessage{},
		keyExpiresAt: map[string]time.Time{},
		submissions:  map[string]Submission{},
		failOn:       map[string]error{},
	}
}

func (f *fakeRepo) InsertAudit(ctx context.Context, actor, action string, details any) error {
	if err := f.failOn["InsertAudit"]; err != nil {
		return err
	}
	f.auditLog = append(f.auditLog, auditEntry{actor: actor, action: action, details: details})
	return nil
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
	f.keyExpiresAt[s.IdempotencyKey] = time.Now().Add(24 * time.Hour)
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

func (f *fakeRepo) ReapExpiredPendingKeys(ctx context.Context, before time.Time) (int64, error) {
	if err := f.failOn["ReapExpiredPendingKeys"]; err != nil {
		return 0, err
	}
	var reaped int64
	for key, status := range f.keyStatus {
		if status != "pending" {
			continue
		}
		if exp, ok := f.keyExpiresAt[key]; ok && exp.Before(before) {
			delete(f.keyStatus, key)
			delete(f.keyExpiresAt, key)
			delete(f.keyResponse, key)
			reaped++
		}
	}
	return reaped, nil
}
