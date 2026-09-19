// Package dbx provides the async-connect + readiness boot pattern every
// stateful service uses (Agent-Tale's cmd/authsvc/main.go, adopted per the
// plan's "Referans projelerden alınan boot kalıpları"): the HTTP server
// starts and answers /health immediately; the pool connects in the
// background with retry, and db_ready flips to true once it succeeds.
// Handlers that need the DB are guarded by RequireReady.
package dbx

import (
	"context"
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/local-payment/backend/pkg/httpx"
)

// Pool wraps a *pgxpool.Pool with an atomic readiness flag set once the
// background connect attempt succeeds.
type Pool struct {
	pool  atomic.Pointer[pgxpool.Pool]
	ready atomic.Bool
}

// ConnectAsync starts connecting to dsn in the background, retrying every
// 2s until it succeeds or ctx is canceled. Call this once at boot, before
// http.ListenAndServe — never block main() on it.
func ConnectAsync(ctx context.Context, dsn string, logger *slog.Logger) *Pool {
	p := &Pool{}
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}
			pool, err := pgxpool.New(ctx, dsn)
			if err != nil {
				logger.Warn("db connect failed, retrying", "error", err)
				time.Sleep(2 * time.Second)
				continue
			}
			if err := pool.Ping(ctx); err != nil {
				logger.Warn("db ping failed, retrying", "error", err)
				pool.Close()
				time.Sleep(2 * time.Second)
				continue
			}
			p.pool.Store(pool)
			p.ready.Store(true)
			logger.Info("db ready")
			return
		}
	}()
	return p
}

// Ready reports whether the pool has connected — the /health db_ready flag.
func (p *Pool) Ready() bool { return p.ready.Load() }

// Get returns the underlying pool, or nil if not yet connected.
func (p *Pool) Get() *pgxpool.Pool { return p.pool.Load() }

// RequireReady is middleware that answers 503 chain.rpc_unavailable-shaped
// (domain-scoped by the caller via code) until the pool is up, so a request
// during the brief post-boot window fails cleanly instead of nil-pointer
// panicking.
func RequireReady(p *Pool, code string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !p.Ready() {
			httpx.WriteError(w, http.StatusServiceUnavailable, code, "database not ready yet", nil)
			return
		}
		next.ServeHTTP(w, r)
	})
}
