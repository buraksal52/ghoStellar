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

// TestSubmit_GatewayErrorReleasesKeyForRetry is SERVICE.md #14/#23's
// regression test: a chain-gateway/Horizon-level error (never reaching the
// network's own verdict) must release the idempotency key instead of
// caching the failure as "done" — otherwise a retried offline payment (or
// any client honoring D3) would replay the SAME transient failure forever
// via GetIdempotentResponse, even long after the outage cleared.
func TestSubmit_GatewayErrorReleasesKeyForRetry(t *testing.T) {
	repo := newFakeRepo()
	calls := 0
	chain := &portstest.FakeChain{
		SubmitClassicFunc: func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
			calls++
			if calls == 1 {
				return ports.SubmitResult{}, errors.New("horizon: connection refused")
			}
			return ports.SubmitResult{Hash: "hash-1", Successful: true}, nil
		},
	}
	svc := newServiceWithRepo(repo, chain)
	req := SubmitRequest{IdempotencyKey: "key-1", Kind: KindClassic, SignedXDR: "AAAA=="}

	if _, err := svc.Submit(context.Background(), req); err == nil {
		t.Fatal("expected an error when the chain gateway itself fails")
	}
	sub := repo.submissions["key-1"]
	if sub.State != "failed" {
		t.Errorf("recorded state = %q, want %q", sub.State, "failed")
	}
	// The key must NOT be marked done: a gateway error is not the network's
	// verdict, so the caller must be able to retry with the same key.
	if status, ok := repo.keyStatus["key-1"]; ok {
		t.Errorf("keyStatus = %q, want key to be released (absent)", status)
	}

	resp, err := svc.Submit(context.Background(), req)
	if err != nil {
		t.Fatalf("retry after gateway error: %v", err)
	}
	if resp.Replayed {
		t.Fatal("the retry reached the chain for real and must not be marked Replayed")
	}
	if !resp.Successful || resp.Hash != "hash-1" {
		t.Fatalf("got %+v, want a successful resubmission", resp)
	}
	if calls != 2 {
		t.Fatalf("chain was called %d times, want exactly 2", calls)
	}
}

// TestSubmit_RetryAfterGatewayErrorSucceeds_SameKey extends
// TestSubmit_GatewayErrorReleasesKeyForRetry: after ReleaseSubmission,
// pay.submissions' row for this key still exists (kept as history), so the
// retry's BeginSubmission must be able to write over it, not fail on its
// PRIMARY KEY (SERVICE.md #23 — this used to 500 then 409-forever, which is
// exactly "the offline queue never moves after reconnect").
func TestSubmit_RetryAfterGatewayErrorSucceeds_SameKey(t *testing.T) {
	repo := newFakeRepo()
	calls := 0
	chain := &portstest.FakeChain{
		SubmitClassicFunc: func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
			calls++
			if calls == 1 {
				return ports.SubmitResult{}, errors.New("horizon: connection refused")
			}
			return ports.SubmitResult{Hash: "hash-1", Successful: true}, nil
		},
	}
	svc := newServiceWithRepo(repo, chain)
	req := SubmitRequest{IdempotencyKey: "key-1", Kind: KindClassic, SignedXDR: "AAAA=="}

	if _, err := svc.Submit(context.Background(), req); err == nil {
		t.Fatal("expected an error when the chain gateway itself fails")
	}

	resp, err := svc.Submit(context.Background(), req)
	if err != nil {
		t.Fatalf("retry with the same key must succeed, not 409/500: %v", err)
	}
	if resp.Replayed {
		t.Fatal("the retry reached the chain for real and must not be marked Replayed")
	}
	if repo.submissions["key-1"].State != "success" {
		t.Fatalf("submissions[key-1].State = %q, want %q", repo.submissions["key-1"].State, "success")
	}
}

// TestSubmit_ThreeConsecutiveGatewayErrorsThenSuccess mirrors the offline
// payment queue's 15s retry loop (frontend/lib/state/offline_providers.dart):
// repeated transient failures with the SAME key must never brick it.
func TestSubmit_ThreeConsecutiveGatewayErrorsThenSuccess(t *testing.T) {
	repo := newFakeRepo()
	calls := 0
	chain := &portstest.FakeChain{
		SubmitClassicFunc: func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
			calls++
			if calls <= 3 {
				return ports.SubmitResult{}, errors.New("horizon: connection refused")
			}
			return ports.SubmitResult{Hash: "hash-1", Successful: true}, nil
		},
	}
	svc := newServiceWithRepo(repo, chain)
	req := SubmitRequest{IdempotencyKey: "key-1", Kind: KindClassic, SignedXDR: "AAAA=="}

	for i := 0; i < 3; i++ {
		if _, err := svc.Submit(context.Background(), req); err == nil {
			t.Fatalf("attempt %d: expected a gateway error", i+1)
		}
		if _, ok := repo.keyStatus["key-1"]; ok {
			t.Fatalf("attempt %d: keyStatus must be released after a gateway error", i+1)
		}
	}

	resp, err := svc.Submit(context.Background(), req)
	if err != nil {
		t.Fatalf("4th attempt: expected success, got %v", err)
	}
	if !resp.Successful || resp.Replayed {
		t.Fatalf("got %+v, want a fresh successful submission", resp)
	}
	if calls != 4 {
		t.Fatalf("chain was called %d times, want exactly 4", calls)
	}
}

// TestSubmit_KeyInFlightStillRejectsConcurrentCall guards that tolerating a
// retry AFTER release (above) did not loosen the single-flight gate for a
// call that arrives WHILE the key is still genuinely pending.
func TestSubmit_KeyInFlightStillRejectsConcurrentCall(t *testing.T) {
	repo := newFakeRepo()
	repo.keyStatus["key-1"] = "pending"
	repo.submissions["key-1"] = Submission{IdempotencyKey: "key-1", State: "pending"}
	svc := newServiceWithRepo(repo, &portstest.FakeChain{})

	_, err := svc.Submit(context.Background(), SubmitRequest{IdempotencyKey: "key-1", Kind: KindClassic, SignedXDR: "AAAA=="})
	if !errors.Is(err, errKeyInFlight) {
		t.Fatalf("got %v, want errKeyInFlight", err)
	}
}

// TestSubmit_ChainRejectionIsCachedAsTerminal is the counterpart: once the
// chain itself has spoken (submitErr == nil, whether or not the transaction
// was accepted), that IS the network's verdict — D3's idempotency cache
// must still make it replay-safe, unlike a gateway-level error. tx_too_late
// stands in for "final": the signed TimeBounds can never become valid again.
func TestSubmit_ChainRejectionIsCachedAsTerminal(t *testing.T) {
	repo := newFakeRepo()
	chain := &portstest.FakeChain{
		SubmitClassicFunc: func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
			return ports.SubmitResult{Hash: "hash-1", Successful: false, ResultCode: "tx_too_late"}, nil
		},
	}
	svc := newServiceWithRepo(repo, chain)
	req := SubmitRequest{IdempotencyKey: "key-1", Kind: KindClassic, SignedXDR: "AAAA=="}

	first, err := svc.Submit(context.Background(), req)
	if err != nil {
		t.Fatalf("Submit: %v", err)
	}
	if first.Successful || first.ResultCode != "tx_too_late" {
		t.Fatalf("got %+v, want a recorded rejection", first)
	}
	if repo.keyStatus["key-1"] != "done" {
		t.Errorf("keyStatus = %q, want %q", repo.keyStatus["key-1"], "done")
	}

	second, err := svc.Submit(context.Background(), req)
	if err != nil {
		t.Fatalf("replayed Submit: %v", err)
	}
	if !second.Replayed {
		t.Fatal("a genuine chain rejection must still be replayed from cache, not resubmitted")
	}
	if chain.SubmitClassicCalls != 1 {
		t.Fatalf("chain was called %d times, want exactly 1", chain.SubmitClassicCalls)
	}
}

// TestSubmit_BadSeqIsNotCachedSoALaterRetryReachesTheChain: an offline payment
// signed ahead of the chain gets tx_bad_seq until the payments in front of it
// land. That verdict must reach the caller but must NOT become the key's
// permanent result, or the payment could never settle once its predecessor
// does.
func TestSubmit_BadSeqIsNotCachedSoALaterRetryReachesTheChain(t *testing.T) {
	repo := newFakeRepo()
	chain := &portstest.FakeChain{}
	chain.SubmitClassicFunc = func(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
		if chain.SubmitClassicCalls == 1 {
			return ports.SubmitResult{Hash: "hash-1", Successful: false, ResultCode: "tx_bad_seq"}, nil
		}
		return ports.SubmitResult{Hash: "hash-1", Successful: true}, nil
	}
	svc := newServiceWithRepo(repo, chain)
	req := SubmitRequest{IdempotencyKey: "key-1", Kind: KindClassic, SignedXDR: "AAAA=="}

	first, err := svc.Submit(context.Background(), req)
	if err != nil {
		t.Fatalf("Submit: %v", err)
	}
	if first.Successful || first.ResultCode != "tx_bad_seq" || first.Replayed {
		t.Fatalf("got %+v, want the uncached tx_bad_seq verdict", first)
	}
	if repo.keyStatus["key-1"] == "done" {
		t.Fatal("tx_bad_seq must not leave the key in 'done'")
	}

	second, err := svc.Submit(context.Background(), req)
	if err != nil {
		t.Fatalf("retry Submit: %v", err)
	}
	if second.Replayed || !second.Successful {
		t.Fatalf("got %+v, want a fresh, successful submission", second)
	}
	if chain.SubmitClassicCalls != 2 {
		t.Fatalf("chain was called %d times, want 2 (the retry must reach it)", chain.SubmitClassicCalls)
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
