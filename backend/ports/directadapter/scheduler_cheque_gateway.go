package directadapter

import (
	"context"

	"github.com/local-payment/backend/services/cheque"
	"github.com/local-payment/backend/services/scheduler"
)

// SchedulerChequeGateway wraps a *cheque.Service so pay-scheduler-service's
// sweep can run in-process (the monolith profile) instead of over HTTP
// through scheduler.ChequeClient — SERVICE.md #4. It satisfies the same
// small interface scheduler.Service depends on (unexported there), so it
// can be passed to scheduler.NewService interchangeably with a
// *scheduler.ChequeClient.
type SchedulerChequeGateway struct {
	svc *cheque.Service
}

func NewSchedulerChequeGateway(svc *cheque.Service) *SchedulerChequeGateway {
	return &SchedulerChequeGateway{svc: svc}
}

// ExpiredFundedCheques maps cheque.Service's own Cheque rows onto
// scheduler.ExpiredCheque — a plain field-for-field narrowing, since the
// sweep only ever needs the columns scheduler.ExpiredCheque already
// declares.
func (a *SchedulerChequeGateway) ExpiredFundedCheques(ctx context.Context) ([]scheduler.ExpiredCheque, error) {
	cheques, err := a.svc.ExpiredFundedCheques(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]scheduler.ExpiredCheque, len(cheques))
	for i, c := range cheques {
		out[i] = scheduler.ExpiredCheque{
			ID:              c.ID,
			SenderAddress:   c.SenderAddress,
			ReceiverAddress: c.ReceiverAddress,
			TokenContract:   c.TokenContract,
			AmountRaw:       c.AmountRaw,
			Decimals:        c.Decimals,
		}
	}
	return out, nil
}

func (a *SchedulerChequeGateway) MarkRefunded(ctx context.Context, chequeID, txHash string) error {
	return a.svc.MarkRefunded(ctx, chequeID, txHash)
}
