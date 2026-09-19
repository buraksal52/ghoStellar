package tx

import "time"

// Kind selects which chain-gateway submit path a request needs.
type Kind string

const (
	KindClassic Kind = "classic"
	KindSoroban Kind = "soroban"
)

// Submission is one row of pay.submissions: the durable record of every
// signed XDR pay-tx-service has ever forwarded, regardless of which domain
// (cheque, pool, anchor withdraw) originated it.
type Submission struct {
	IdempotencyKey string    `json:"idempotencyKey"`
	StellarAddress string    `json:"-"`
	Purpose        string    `json:"purpose"`
	TxHash         string    `json:"txHash,omitempty"`
	State          string    `json:"state"` // pending | submitted | success | failed
	ResultCode     string    `json:"resultCode,omitempty"`
	CreatedAt      time.Time `json:"createdAt"`
	UpdatedAt      time.Time `json:"updatedAt"`
}
