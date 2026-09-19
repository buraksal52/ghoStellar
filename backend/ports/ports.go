// Package ports defines the interfaces services depend on instead of
// importing each other directly (docs/reference/platform/architecture.md
// §4.1). Two adapters implement each port: httpadapter (microservice mode,
// internal HTTP + X-Internal-Api-Key) and directadapter (monolith mode, a
// plain in-process function call). Every other service depends on
// ChainGateway — never on Horizon/Soroban RPC directly — so that
// "yalnızca pay-chain-gateway zincire çıkar" is enforced by the type
// system, not just by convention.
package ports

import "context"

// Balance is one line of an account's trustline/holdings, as reported by
// pay-chain-gateway. Amount is a decimal string per the money package's
// API-boundary rule — never a JSON number.
type Balance struct {
	AssetCode   string `json:"assetCode"` // "native" for XLM
	AssetIssuer string `json:"assetIssuer,omitempty"`
	Balance     string `json:"balance"`
	Limit       string `json:"limit,omitempty"`
}

// AccountInfo is the minimal account state other services need to build
// unsigned transactions: the sequence number (to build the next tx) and
// balances (to check trustlines and spendable amounts).
type AccountInfo struct {
	Address  string    `json:"address"`
	Sequence int64     `json:"sequence"`
	Balances []Balance `json:"balances"`
	Exists   bool      `json:"exists"`
}

// TrustlineInfo answers "can this account hold this asset" (p2p doc A4/F3).
type TrustlineInfo struct {
	Exists  bool   `json:"exists"`
	Balance string `json:"balance,omitempty"`
	Limit   string `json:"limit,omitempty"`
}

// LedgerInfo is the chain's own clock (D7: no authorization decision is
// ever made from a device's clock).
type LedgerInfo struct {
	Sequence  int64 `json:"sequence"`
	CloseTime int64 `json:"closeTime"` // unix seconds
}

// SimulateResult is a trimmed view of Soroban's simulateTransaction
// response: just enough for a caller to assemble a submittable transaction
// (resource footprint + fee) without depending on the RPC wire format.
type SimulateResult struct {
	Success            bool   `json:"success"`
	Error              string `json:"error,omitempty"`
	TransactionDataXDR string `json:"transactionDataXdr,omitempty"`
	MinResourceFee     int64  `json:"minResourceFee,omitempty"`
	ResultXDR          string `json:"resultXdr,omitempty"`
}

// SubmitResult is the outcome of handing a signed envelope to the network,
// classic or Soroban.
type SubmitResult struct {
	Hash       string `json:"hash"`
	Successful bool   `json:"successful"`
	ResultCode string `json:"resultCode,omitempty"`
	LedgerSeq  int64  `json:"ledgerSeq,omitempty"`
}

// ChainGateway is the single port every other service uses to reach the
// chain. Implemented by httpadapter (calls pay-chain-gateway over internal
// HTTP) and directadapter (calls the chain service in-process).
type ChainGateway interface {
	GetAccount(ctx context.Context, address string) (AccountInfo, error)
	GetTrustline(ctx context.Context, address, assetCode, assetIssuer string) (TrustlineInfo, error)
	GetLedger(ctx context.Context) (LedgerInfo, error)
	SimulateTransaction(ctx context.Context, unsignedXDR string) (SimulateResult, error)
	SubmitClassic(ctx context.Context, signedXDR string) (SubmitResult, error)
	SubmitSoroban(ctx context.Context, signedXDR string) (SubmitResult, error)
	Fund(ctx context.Context, address string) error // testnet friendbot only
}
