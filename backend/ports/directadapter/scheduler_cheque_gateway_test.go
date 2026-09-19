package directadapter

import (
	"context"
	"testing"

	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/ports/portstest"
	"github.com/local-payment/backend/services/cheque"
)

// TestSchedulerChequeGateway_DBNotReady exercises the adapter through the
// production cheque.NewService constructor (an unconnected *dbx.Pool)
// rather than a test-only seam, since the adapter itself has no logic
// beyond forwarding — proving it forwards to a real *cheque.Service (and
// fails cleanly, not with a panic) is the whole point here.
func TestSchedulerChequeGateway_DBNotReady(t *testing.T) {
	pool := &dbx.Pool{} // never connected
	svc := cheque.NewService(cheque.Config{}, pool, &portstest.FakeChain{})
	gw := NewSchedulerChequeGateway(svc)

	if _, err := gw.ExpiredFundedCheques(context.Background()); err == nil {
		t.Fatal("expected an error when the DB is not ready")
	}
	if err := gw.MarkRefunded(context.Background(), "01AA", "hash"); err == nil {
		t.Fatal("expected an error when the DB is not ready")
	}
}
