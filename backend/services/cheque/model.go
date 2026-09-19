// Package cheque implements pay-cheque-service: the Çek (P2P cheque) and
// Havuz (pool) state machine, reservation ledger, unsigned-XDR production,
// and the Forced Sync endpoint. See
// docs/reference/platform/p2p-cek-ve-havuz-mimarisi.md §4, §9.
package cheque

import "time"

// State mirrors p2p-cek-ve-havuz-mimarisi.md §4's state machine exactly,
// including the pre-chain states (Taslak/ImzaliRezerve) that exist only in
// this database, before anything reaches the network.
type State string

const (
	StateTaslak             State = "TASLAK"
	StateImzaliRezerve      State = "IMZALI_REZERVE"
	StateFonlaniyor         State = "FONLANIYOR"
	StateHavuzda            State = "HAVUZDA"
	StateTalepEdildi        State = "TALEP_EDILDI"
	StateOnaylandi          State = "ONAYLANDI"
	StateKapandi            State = "KAPANDI"
	StateIadeEdilebilir     State = "IADE_EDILEBILIR"
	StateIadeEdildi         State = "IADE_EDILDI"
	StateHukumsuz           State = "HUKUMSUZ"
	StateZorlaTahsilDenendi State = "ZORLA_TAHSIL_DENENDI"
	StateKarsiliksiz        State = "KARSILIKSIZ"
)

// terminal states — D4: no transition ever leaves one of these.
var terminalStates = map[State]bool{
	StateKapandi:     true,
	StateIadeEdildi:  true,
	StateHukumsuz:    true,
	StateKarsiliksiz: true,
}

func (s State) IsTerminal() bool { return terminalStates[s] }

// Cheque is one row of pay.cheques.
type Cheque struct {
	ID              string    `json:"id"`
	SenderAddress   string    `json:"senderAddress"`
	ReceiverAddress string    `json:"receiverAddress"`
	TokenContract   string    `json:"tokenContract"`
	AmountRaw       string    `json:"amountRaw"` // decimal string, money.Amount.String() shape
	Decimals        uint8     `json:"decimals"`
	State           State     `json:"state"`
	ExpiresAt       time.Time `json:"expiresAt"`
	LockTxHash      string    `json:"lockTxHash,omitempty"`
	PreauthEntryXDR string    `json:"-"` // never serialized to a user-facing response; force-collect-xdr reads it server-side only
	CreatedAt       time.Time `json:"createdAt"`
	UpdatedAt       time.Time `json:"updatedAt"`
}

// PoolDeposit is one row of pay.pool_deposits.
type PoolDeposit struct {
	OwnerAddress      string    `json:"ownerAddress"`
	AmountRaw         string    `json:"amountRaw"`
	Decimals          uint8     `json:"decimals"`
	LastDepositLedger int64     `json:"lastDepositLedger,omitempty"`
	UpdatedAt         time.Time `json:"updatedAt"`
}

// SyncView is the Forced Sync response: everything the app needs to decide
// what to show, in one call, doğrulanmış (this MVP verifies against the
// local cache the write endpoints and pay-scheduler-service keep honest —
// see SERVICE.md's "Kapsam sınırlaması" note for the full chain-reconcile
// version this stands in for).
type SyncView struct {
	Cheques        []Cheque    `json:"cheques"`
	Pool           PoolDeposit `json:"pool"`
	TrustlineReady bool        `json:"trustlineReady"`
	Ledger         int64       `json:"ledgerSeq"`
	ServerTimeUnix int64       `json:"serverTimeUnix"`
}
