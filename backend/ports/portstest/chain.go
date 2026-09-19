// Package portstest provides a test double for ports.ChainGateway, shared
// by every service package's tests instead of each reinventing its own
// fake. It is an ordinary (non-_test.go) package so it can be imported by
// any package's tests without duplicating the type per package.
package portstest

import (
	"context"

	"github.com/local-payment/backend/ports"
)

// FakeChain is a ports.ChainGateway test double. Each field is a function
// hook; a nil hook returns the zero value and a nil error, so a test only
// needs to set the hooks it cares about. Call counts let a test assert a
// method was (or was not) invoked at all — used e.g. to prove tx-service's
// idempotency replay path never touches the chain twice.
type FakeChain struct {
	GetAccountFunc          func(ctx context.Context, address string) (ports.AccountInfo, error)
	GetTrustlineFunc        func(ctx context.Context, address, assetCode, assetIssuer string) (ports.TrustlineInfo, error)
	GetLedgerFunc           func(ctx context.Context) (ports.LedgerInfo, error)
	SimulateTransactionFunc func(ctx context.Context, unsignedXDR string) (ports.SimulateResult, error)
	SubmitClassicFunc       func(ctx context.Context, signedXDR string) (ports.SubmitResult, error)
	SubmitSorobanFunc       func(ctx context.Context, signedXDR string) (ports.SubmitResult, error)
	FundFunc                func(ctx context.Context, address string) error

	GetAccountCalls          int
	GetTrustlineCalls        int
	GetLedgerCalls           int
	SimulateTransactionCalls int
	SubmitClassicCalls       int
	SubmitSorobanCalls       int
	FundCalls                int
}

var _ ports.ChainGateway = (*FakeChain)(nil)

func (f *FakeChain) GetAccount(ctx context.Context, address string) (ports.AccountInfo, error) {
	f.GetAccountCalls++
	if f.GetAccountFunc != nil {
		return f.GetAccountFunc(ctx, address)
	}
	return ports.AccountInfo{}, nil
}

func (f *FakeChain) GetTrustline(ctx context.Context, address, assetCode, assetIssuer string) (ports.TrustlineInfo, error) {
	f.GetTrustlineCalls++
	if f.GetTrustlineFunc != nil {
		return f.GetTrustlineFunc(ctx, address, assetCode, assetIssuer)
	}
	return ports.TrustlineInfo{}, nil
}

func (f *FakeChain) GetLedger(ctx context.Context) (ports.LedgerInfo, error) {
	f.GetLedgerCalls++
	if f.GetLedgerFunc != nil {
		return f.GetLedgerFunc(ctx)
	}
	return ports.LedgerInfo{}, nil
}

func (f *FakeChain) SimulateTransaction(ctx context.Context, unsignedXDR string) (ports.SimulateResult, error) {
	f.SimulateTransactionCalls++
	if f.SimulateTransactionFunc != nil {
		return f.SimulateTransactionFunc(ctx, unsignedXDR)
	}
	return ports.SimulateResult{Success: true}, nil
}

func (f *FakeChain) SubmitClassic(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
	f.SubmitClassicCalls++
	if f.SubmitClassicFunc != nil {
		return f.SubmitClassicFunc(ctx, signedXDR)
	}
	return ports.SubmitResult{}, nil
}

func (f *FakeChain) SubmitSoroban(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
	f.SubmitSorobanCalls++
	if f.SubmitSorobanFunc != nil {
		return f.SubmitSorobanFunc(ctx, signedXDR)
	}
	return ports.SubmitResult{}, nil
}

func (f *FakeChain) Fund(ctx context.Context, address string) error {
	f.FundCalls++
	if f.FundFunc != nil {
		return f.FundFunc(ctx, address)
	}
	return nil
}
