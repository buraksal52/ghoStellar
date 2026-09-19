// Package directadapter implements every port with a plain in-process call
// into the corresponding service — the monolith profile's wiring
// (docs/reference/platform/architecture.md §4.1). No HTTP, no
// X-Internal-Api-Key, just a function call.
package directadapter

import (
	"context"

	"github.com/local-payment/backend/ports"
	"github.com/local-payment/backend/services/chain"
)

// ChainGateway wraps a *chain.Service so it satisfies ports.ChainGateway
// without going through HTTP.
type ChainGateway struct {
	svc *chain.Service
}

var _ ports.ChainGateway = (*ChainGateway)(nil)

func NewChainGateway(svc *chain.Service) *ChainGateway {
	return &ChainGateway{svc: svc}
}

func (a *ChainGateway) GetAccount(ctx context.Context, address string) (ports.AccountInfo, error) {
	return a.svc.GetAccount(ctx, address)
}

func (a *ChainGateway) GetTrustline(ctx context.Context, address, assetCode, assetIssuer string) (ports.TrustlineInfo, error) {
	return a.svc.GetTrustline(ctx, address, assetCode, assetIssuer)
}

func (a *ChainGateway) GetLedger(ctx context.Context) (ports.LedgerInfo, error) {
	return a.svc.GetLedger(ctx)
}

func (a *ChainGateway) SimulateTransaction(ctx context.Context, unsignedXDR string) (ports.SimulateResult, error) {
	return a.svc.SimulateTransaction(ctx, unsignedXDR)
}

func (a *ChainGateway) SubmitClassic(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
	return a.svc.SubmitClassic(ctx, signedXDR)
}

func (a *ChainGateway) SubmitSoroban(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
	return a.svc.SubmitSoroban(ctx, signedXDR)
}

func (a *ChainGateway) Fund(ctx context.Context, address string) error {
	return a.svc.Fund(ctx, address)
}
