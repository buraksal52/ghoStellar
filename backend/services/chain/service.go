// Package chain is pay-chain-gateway's own implementation: the single
// place in the whole backend that talks to Horizon and Soroban RPC
// directly (docs/reference/platform/architecture.md §4 rule 2). Every
// other service reaches it only through ports.ChainGateway.
package chain

import (
	"context"
	"errors"
	"fmt"
	"net/http"

	"github.com/stellar/go-stellar-sdk/clients/horizonclient"
	"github.com/stellar/go-stellar-sdk/clients/rpcclient"
	"github.com/stellar/go-stellar-sdk/protocols/horizon"
	rpcprotocol "github.com/stellar/go-stellar-sdk/protocols/rpc"

	"github.com/local-payment/backend/ports"
)

// sendTransactionStatusError is Soroban RPC's sendTransaction "ERROR"
// status. Unlike TransactionStatusSuccess/Failed (get_transaction.go), the
// SDK does not export a constant for it, so it is spelled out once here.
const sendTransactionStatusError = "ERROR"

// Config configures a Service. SorobanRPCURL empty means Soroban support is
// disabled (the "boş env var = özellik kapalı" contract, architecture.md
// §4.6) — the service still starts, but Soroban-only endpoints answer
// chain.soroban_disabled.
type Config struct {
	HorizonURL    string
	SorobanRPCURL string
	NetworkPass   string
}

// ErrSorobanDisabled is returned by every Soroban-dependent method when
// SorobanRPCURL was left empty.
var ErrSorobanDisabled = errors.New("chain: soroban rpc not configured")

// Service is the real Horizon/Soroban client. It implements
// ports.ChainGateway directly, so directadapter (monolith mode) can wrap it
// with zero glue, and pay-chain-gateway's own HTTP handlers call it too.
type Service struct {
	cfg     Config
	horizon *horizonclient.Client
	rpc     *rpcclient.Client
}

var _ ports.ChainGateway = (*Service)(nil)

// NewService constructs a Service. hc should already be wrapped by
// pkg/nethost's SSRF allow-list (nethost.Client) — this is the one place in
// the backend that HTTP client is allowed to actually reach the network.
func NewService(cfg Config, hc *http.Client) *Service {
	horizonC := &horizonclient.Client{HorizonURL: cfg.HorizonURL, HTTP: hc}
	var rpc *rpcclient.Client
	if cfg.SorobanRPCURL != "" {
		rpc = rpcclient.NewClient(cfg.SorobanRPCURL, hc)
	}
	return &Service{cfg: cfg, horizon: horizonC, rpc: rpc}
}

func (s *Service) GetAccount(ctx context.Context, address string) (ports.AccountInfo, error) {
	acc, err := s.horizon.AccountDetail(horizonclient.AccountRequest{AccountID: address})
	if err != nil {
		if horizonclient.IsNotFoundError(err) {
			return ports.AccountInfo{Address: address, Exists: false}, nil
		}
		return ports.AccountInfo{}, fmt.Errorf("chain: account detail: %w", err)
	}
	return ports.AccountInfo{
		Address:  address,
		Sequence: acc.Sequence,
		Exists:   true,
		Balances: toBalances(acc.Balances),
	}, nil
}

func (s *Service) GetTrustline(ctx context.Context, address, assetCode, assetIssuer string) (ports.TrustlineInfo, error) {
	acc, err := s.horizon.AccountDetail(horizonclient.AccountRequest{AccountID: address})
	if err != nil {
		if horizonclient.IsNotFoundError(err) {
			return ports.TrustlineInfo{Exists: false}, nil
		}
		return ports.TrustlineInfo{}, fmt.Errorf("chain: account detail: %w", err)
	}
	for _, b := range acc.Balances {
		if assetCode == "native" && b.Type == "native" {
			return ports.TrustlineInfo{Exists: true, Balance: b.Balance}, nil
		}
		if b.Code == assetCode && b.Issuer == assetIssuer {
			return ports.TrustlineInfo{Exists: true, Balance: b.Balance, Limit: b.Limit}, nil
		}
	}
	return ports.TrustlineInfo{Exists: false}, nil
}

func (s *Service) GetLedger(ctx context.Context) (ports.LedgerInfo, error) {
	root, err := s.horizon.Root()
	if err != nil {
		return ports.LedgerInfo{}, fmt.Errorf("chain: root: %w", err)
	}
	ledger, err := s.horizon.LedgerDetail(uint32(root.HorizonSequence))
	if err != nil {
		return ports.LedgerInfo{}, fmt.Errorf("chain: ledger detail: %w", err)
	}
	return ports.LedgerInfo{Sequence: int64(ledger.Sequence), CloseTime: ledger.ClosedAt.Unix()}, nil
}

func (s *Service) SimulateTransaction(ctx context.Context, unsignedXDR string) (ports.SimulateResult, error) {
	if s.rpc == nil {
		return ports.SimulateResult{}, ErrSorobanDisabled
	}
	resp, err := s.rpc.SimulateTransaction(ctx, rpcprotocol.SimulateTransactionRequest{Transaction: unsignedXDR})
	if err != nil {
		return ports.SimulateResult{}, fmt.Errorf("chain: simulate: %w", err)
	}
	if resp.Error != "" {
		return ports.SimulateResult{Success: false, Error: resp.Error}, nil
	}
	result := ports.SimulateResult{
		Success:            true,
		MinResourceFee:     resp.MinResourceFee,
		TransactionDataXDR: resp.TransactionDataXDR,
	}
	if len(resp.Results) > 0 && resp.Results[0].ReturnValueXDR != nil {
		result.ResultXDR = *resp.Results[0].ReturnValueXDR
	}
	return result, nil
}

func (s *Service) SubmitClassic(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
	tx, err := s.horizon.SubmitTransactionXDR(signedXDR)
	if err != nil {
		if herr, ok := errors.AsType[*horizonclient.Error](err); ok {
			codeStr := ""
			if codes, cerr := herr.ResultCodes(); cerr == nil && codes != nil {
				codeStr = codes.TransactionCode
			}
			return ports.SubmitResult{Successful: false, ResultCode: codeStr}, nil
		}
		return ports.SubmitResult{}, fmt.Errorf("chain: submit: %w", err)
	}
	return ports.SubmitResult{Hash: tx.Hash, Successful: tx.Successful, LedgerSeq: int64(tx.Ledger)}, nil
}

func (s *Service) SubmitSoroban(ctx context.Context, signedXDR string) (ports.SubmitResult, error) {
	if s.rpc == nil {
		return ports.SubmitResult{}, ErrSorobanDisabled
	}
	resp, err := s.rpc.SendTransaction(ctx, rpcprotocol.SendTransactionRequest{Transaction: signedXDR})
	if err != nil {
		return ports.SubmitResult{}, fmt.Errorf("chain: send transaction: %w", err)
	}
	if resp.Status == sendTransactionStatusError {
		return ports.SubmitResult{Hash: resp.Hash, Successful: false, ResultCode: resp.ErrorResultXDR}, nil
	}

	final, err := s.rpc.PollTransaction(ctx, resp.Hash)
	if err != nil {
		// Submitted but not confirmed within the poll window — the caller
		// (pay-tx-service) tracks this as PENDING and re-queries later; it
		// never resubmits (B2: idempotent re-query, never a duplicate send).
		return ports.SubmitResult{Hash: resp.Hash, Successful: false, ResultCode: "PENDING"}, nil
	}
	return ports.SubmitResult{
		Hash:       resp.Hash,
		Successful: final.Status == rpcprotocol.TransactionStatusSuccess,
		ResultCode: final.Status,
	}, nil
}

func (s *Service) Fund(ctx context.Context, address string) error {
	if _, err := s.horizon.Fund(address); err != nil {
		return fmt.Errorf("chain: friendbot fund: %w", err)
	}
	return nil
}

func toBalances(hb []horizon.Balance) []ports.Balance {
	out := make([]ports.Balance, 0, len(hb))
	for _, b := range hb {
		code := b.Code
		if b.Type == "native" {
			code = "native"
		}
		out = append(out, ports.Balance{
			AssetCode:   code,
			AssetIssuer: b.Issuer,
			Balance:     b.Balance,
			Limit:       b.Limit,
		})
	}
	return out
}
