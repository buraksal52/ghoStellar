package tx

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/ports"
	"github.com/local-payment/backend/ports/portstest"
)

func TestSubmit_ClassicVsSoroban(t *testing.T) {
	for _, tc := range []struct {
		kind       Kind
		wantSubmit string // which FakeChain call should be invoked
	}{
		{KindClassic, "classic"},
		{KindSoroban, "soroban"},
	} {
		t.Run(string(tc.kind), func(t *testing.T) {
			chain := &portstest.FakeChain{
				SubmitClassicFunc: func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
					return ports.SubmitResult{Hash: "classic-hash", Successful: true}, nil
				},
				SubmitSorobanFunc: func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
					return ports.SubmitResult{Hash: "soroban-hash", Successful: true}, nil
				},
			}
			svc := newServiceWithRepo(newFakeRepo(), chain)
			resp, err := svc.Submit(context.Background(), SubmitRequest{
				IdempotencyKey: "key-1", StellarAddress: "GADDR", Purpose: "cheque.lock", Kind: tc.kind, SignedXDR: "AAAA==",
			})
			if err != nil {
				t.Fatalf("Submit: %v", err)
			}
			if !resp.Successful {
				t.Fatalf("expected Successful=true")
			}
			if tc.kind == KindSoroban {
				if chain.SubmitSorobanCalls != 1 || chain.SubmitClassicCalls != 0 {
					t.Fatalf("soroban=%d classic=%d, want soroban=1 classic=0", chain.SubmitSorobanCalls, chain.SubmitClassicCalls)
				}
			} else {
				if chain.SubmitClassicCalls != 1 || chain.SubmitSorobanCalls != 0 {
					t.Fatalf("classic=%d soroban=%d, want classic=1 soroban=0", chain.SubmitClassicCalls, chain.SubmitSorobanCalls)
				}
			}
		})
	}
}

// TestSubmit_ReplayDoesNotResubmit is D3's core guarantee: a repeated call
// with the same idempotency key must return the FIRST attempt's result and
// must NEVER touch the chain a second time.
func TestSubmit_ReplayDoesNotResubmit(t *testing.T) {
	chain := &portstest.FakeChain{
		SubmitClassicFunc: func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
			return ports.SubmitResult{Hash: "hash-1", Successful: true}, nil
		},
	}
	svc := newServiceWithRepo(newFakeRepo(), chain)
	ctx := context.Background()
	req := SubmitRequest{IdempotencyKey: "key-1", StellarAddress: "GADDR", Purpose: "cheque.lock", Kind: KindClassic, SignedXDR: "AAAA=="}

	first, err := svc.Submit(ctx, req)
	if err != nil {
		t.Fatalf("first Submit: %v", err)
	}
	if first.Replayed {
		t.Fatal("first call must not be marked Replayed")
	}

	second, err := svc.Submit(ctx, req)
	if err != nil {
		t.Fatalf("second Submit: %v", err)
	}
	if !second.Replayed {
		t.Fatal("second call with the same key must be marked Replayed")
	}
	if second.Hash != first.Hash {
		t.Fatalf("replayed hash = %q, want %q", second.Hash, first.Hash)
	}
	if chain.SubmitClassicCalls != 1 {
		t.Fatalf("chain was called %d times, want exactly 1", chain.SubmitClassicCalls)
	}
}

func TestSubmit_KeyInFlightRejected(t *testing.T) {
	repo := newFakeRepo()
	repo.keyStatus["key-1"] = "pending" // simulate a concurrent in-flight submission
	svc := newServiceWithRepo(repo, &portstest.FakeChain{})

	_, err := svc.Submit(context.Background(), SubmitRequest{IdempotencyKey: "key-1", Kind: KindClassic, SignedXDR: "AAAA=="})
	if !errors.Is(err, errKeyInFlight) {
		t.Fatalf("got %v, want errKeyInFlight", err)
	}
}

func TestSubmit_ChainErrorStillRecordsFailedState(t *testing.T) {
	repo := newFakeRepo()
	chain := &portstest.FakeChain{
		SubmitClassicFunc: func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
			return ports.SubmitResult{}, errors.New("horizon: connection refused")
		},
	}
	svc := newServiceWithRepo(repo, chain)

	_, err := svc.Submit(context.Background(), SubmitRequest{IdempotencyKey: "key-1", Kind: KindClassic, SignedXDR: "AAAA=="})
	if err == nil {
		t.Fatal("expected an error when the chain submit fails")
	}
	sub := repo.submissions["key-1"]
	if sub.State != "failed" {
		t.Errorf("recorded state = %q, want %q", sub.State, "failed")
	}
	// The key must still be marked done — a chain failure is a terminal
	// outcome for this key, not something to retry via the same key.
	if repo.keyStatus["key-1"] != "done" {
		t.Errorf("keyStatus = %q, want %q", repo.keyStatus["key-1"], "done")
	}
}

func TestSubmit_PendingResultCodeMapsToSubmittedState(t *testing.T) {
	repo := newFakeRepo()
	chain := &portstest.FakeChain{
		SubmitSorobanFunc: func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
			return ports.SubmitResult{Hash: "h", Successful: false, ResultCode: "PENDING"}, nil
		},
	}
	svc := newServiceWithRepo(repo, chain)

	if _, err := svc.Submit(context.Background(), SubmitRequest{IdempotencyKey: "key-1", Kind: KindSoroban, SignedXDR: "AAAA=="}); err != nil {
		t.Fatalf("Submit: %v", err)
	}
	if repo.submissions["key-1"].State != "submitted" {
		t.Errorf("state = %q, want %q", repo.submissions["key-1"].State, "submitted")
	}
}

func TestGetSubmission_NotFound(t *testing.T) {
	svc := newServiceWithRepo(newFakeRepo(), &portstest.FakeChain{})
	_, err := svc.GetSubmission(context.Background(), "missing-key")
	if !errors.Is(err, errNotFound) {
		t.Fatalf("got %v, want errNotFound", err)
	}
}

// TestReapExpiredKeys_UnblocksRetryWithSameKey is SERVICE.md #14's
// regression test: a key stuck in 'pending' past its expiry must not
// permanently 409 a client retrying with the same Idempotency-Key.
func TestReapExpiredKeys_UnblocksRetryWithSameKey(t *testing.T) {
	repo := newFakeRepo()
	chain := &portstest.FakeChain{
		SubmitClassicFunc: func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
			return ports.SubmitResult{Hash: "h", Successful: true}, nil
		},
	}
	svc := newServiceWithRepo(repo, chain)
	ctx := context.Background()

	// Simulate a process that died mid-submission: the key was claimed
	// (pending) but never completed, and its expiry has already passed.
	repo.keyStatus["stuck-key"] = "pending"
	repo.keyExpiresAt["stuck-key"] = time.Now().Add(-time.Hour)

	if _, err := svc.Submit(ctx, SubmitRequest{IdempotencyKey: "stuck-key", Kind: KindClassic, SignedXDR: "AAAA=="}); !errors.Is(err, errKeyInFlight) {
		t.Fatalf("before reap: got %v, want errKeyInFlight", err)
	}

	n, err := svc.ReapExpiredKeys(ctx)
	if err != nil {
		t.Fatalf("ReapExpiredKeys: %v", err)
	}
	if n != 1 {
		t.Fatalf("reaped %d keys, want 1", n)
	}

	resp, err := svc.Submit(ctx, SubmitRequest{IdempotencyKey: "stuck-key", Kind: KindClassic, SignedXDR: "AAAA=="})
	if err != nil {
		t.Fatalf("after reap: Submit failed: %v", err)
	}
	if resp.Replayed {
		t.Error("after reap, this must be a genuinely fresh submission, not a replay")
	}
}

func TestReapExpiredKeys_LeavesUnexpiredPendingKeysAlone(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(repo, &portstest.FakeChain{})
	repo.keyStatus["fresh-key"] = "pending"
	repo.keyExpiresAt["fresh-key"] = time.Now().Add(time.Hour)

	n, err := svc.ReapExpiredKeys(context.Background())
	if err != nil {
		t.Fatalf("ReapExpiredKeys: %v", err)
	}
	if n != 0 {
		t.Fatalf("reaped %d keys, want 0 (not yet expired)", n)
	}
}

func TestService_DBNotReady(t *testing.T) {
	pool := &dbx.Pool{} // never connected
	svc := NewService(pool, &portstest.FakeChain{})

	_, err := svc.Submit(context.Background(), SubmitRequest{IdempotencyKey: "k"})
	if !errors.Is(err, ErrDBNotReadyErr) {
		t.Fatalf("got %v, want ErrDBNotReadyErr", err)
	}
}
