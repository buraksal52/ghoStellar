// Package anchor implements pay-anchor-service: a stateless SEP-1/SEP-6/
// SEP-10/SEP-12/SEP-38 proxy plus a transaction ledger. It never stores an anchor's JWT —
// that stays on the device — so status updates are self-reported by the
// client after it queries the anchor directly with its own token; see
// docs/reference/platform/anchor-entegrasyonu.md.
package anchor

import "time"

// Info is what GET /anchors returns: an anchor's resolved SEP-1
// capabilities, cached in-process.
type Info struct {
	ID               string `json:"id"`
	Domain           string `json:"domain"`
	SigningKey       string `json:"signingKey"`
	WebAuthEndpoint  string `json:"webAuthEndpoint"`
	TransferServer   string `json:"transferServer,omitempty"`
	KYCServer        string `json:"kycServer,omitempty"`
	QuoteServer      string `json:"quoteServer,omitempty"`
	TransferServer24 string `json:"transferServer24,omitempty"`
	AssetCode        string `json:"assetCode"`
	AssetIssuer      string `json:"assetIssuer"`
}

// Transaction is one row of pay.anchor_transactions.
type Transaction struct {
	ID             string    `json:"id"`
	AnchorID       string    `json:"anchorId"`
	StellarAddress string    `json:"-"`
	Kind           string    `json:"kind"` // deposit | withdraw
	State          string    `json:"state"`
	AmountRaw      string    `json:"amount,omitempty"`
	Decimals       uint8     `json:"decimals,omitempty"`
	StellarTxHash  string    `json:"stellarTxHash,omitempty"`
	StartedAt      time.Time `json:"startedAt"`
	UpdatedAt      time.Time `json:"updatedAt"`
}
