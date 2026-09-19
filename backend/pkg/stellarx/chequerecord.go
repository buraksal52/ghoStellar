package stellarx

import (
	"fmt"
	"math/big"

	"github.com/stellar/go-stellar-sdk/xdr"
)

// ChequeRecordView mirrors contracts/soroban/pay-escrow/src/lib.rs's
// ChequeRecord struct (sender, receiver, token, amount, expires_at, state)
// — the decoded shape of a `get_cheque` simulateTransaction result. State
// is the contract's own ChequeState variant name verbatim (one of
// "Funded", "Claimed", "Refunded", "Collected", "Bounced") — callers map
// that onto their own richer state machine, this package makes no
// assumption about what those states mean.
type ChequeRecordView struct {
	Sender    string
	Receiver  string
	Token     string
	Amount    *big.Int
	ExpiresAt uint64
	State     string
}

// DecodePoolRecord's PoolRecord counterpart — see lib.rs's PoolRecord
// (token, amount, last_deposit_at).
type PoolRecordView struct {
	Token         string
	Amount        *big.Int
	LastDepositAt uint64
}

// DecodeChequeRecord decodes a `get_cheque` result. present=false means the
// contract's `Option<ChequeRecord>` was None (no such cheque ID on-chain
// yet — e.g. the lock tx hasn't confirmed).
func DecodeChequeRecord(val xdr.ScVal) (view ChequeRecordView, present bool, err error) {
	present, inner := DecodeOptional(val)
	if !present {
		return ChequeRecordView{}, false, nil
	}
	m, err := decodeMap(inner)
	if err != nil {
		return ChequeRecordView{}, false, fmt.Errorf("stellarx: decode ChequeRecord: %w", err)
	}

	get := func(field string) (xdr.ScVal, error) {
		v, ok := scMapGet(m, field)
		if !ok {
			return xdr.ScVal{}, fmt.Errorf("stellarx: ChequeRecord missing field %q", field)
		}
		return v, nil
	}

	senderVal, err := get("sender")
	if err != nil {
		return ChequeRecordView{}, false, err
	}
	sender, err := DecodeScAddress(senderVal)
	if err != nil {
		return ChequeRecordView{}, false, fmt.Errorf("stellarx: ChequeRecord.sender: %w", err)
	}

	receiverVal, err := get("receiver")
	if err != nil {
		return ChequeRecordView{}, false, err
	}
	receiver, err := DecodeScAddress(receiverVal)
	if err != nil {
		return ChequeRecordView{}, false, fmt.Errorf("stellarx: ChequeRecord.receiver: %w", err)
	}

	tokenVal, err := get("token")
	if err != nil {
		return ChequeRecordView{}, false, err
	}
	token, err := DecodeScAddress(tokenVal)
	if err != nil {
		return ChequeRecordView{}, false, fmt.Errorf("stellarx: ChequeRecord.token: %w", err)
	}

	amountVal, err := get("amount")
	if err != nil {
		return ChequeRecordView{}, false, err
	}
	amount, err := DecodeScI128(amountVal)
	if err != nil {
		return ChequeRecordView{}, false, fmt.Errorf("stellarx: ChequeRecord.amount: %w", err)
	}

	expiresAtVal, err := get("expires_at")
	if err != nil {
		return ChequeRecordView{}, false, err
	}
	expiresAt, err := DecodeScUint64(expiresAtVal)
	if err != nil {
		return ChequeRecordView{}, false, fmt.Errorf("stellarx: ChequeRecord.expires_at: %w", err)
	}

	stateVal, err := get("state")
	if err != nil {
		return ChequeRecordView{}, false, err
	}
	state, err := decodeUnitEnum(stateVal)
	if err != nil {
		return ChequeRecordView{}, false, fmt.Errorf("stellarx: ChequeRecord.state: %w", err)
	}

	return ChequeRecordView{
		Sender: sender, Receiver: receiver, Token: token,
		Amount: amount, ExpiresAt: expiresAt, State: state,
	}, true, nil
}

// DecodePoolRecord decodes a `get_pool` result. present=false means the
// contract's `Option<PoolRecord>` was None (no deposit ever recorded for
// this owner).
func DecodePoolRecord(val xdr.ScVal) (view PoolRecordView, present bool, err error) {
	present, inner := DecodeOptional(val)
	if !present {
		return PoolRecordView{}, false, nil
	}
	m, err := decodeMap(inner)
	if err != nil {
		return PoolRecordView{}, false, fmt.Errorf("stellarx: decode PoolRecord: %w", err)
	}

	get := func(field string) (xdr.ScVal, error) {
		v, ok := scMapGet(m, field)
		if !ok {
			return xdr.ScVal{}, fmt.Errorf("stellarx: PoolRecord missing field %q", field)
		}
		return v, nil
	}

	tokenVal, err := get("token")
	if err != nil {
		return PoolRecordView{}, false, err
	}
	token, err := DecodeScAddress(tokenVal)
	if err != nil {
		return PoolRecordView{}, false, fmt.Errorf("stellarx: PoolRecord.token: %w", err)
	}

	amountVal, err := get("amount")
	if err != nil {
		return PoolRecordView{}, false, err
	}
	amount, err := DecodeScI128(amountVal)
	if err != nil {
		return PoolRecordView{}, false, fmt.Errorf("stellarx: PoolRecord.amount: %w", err)
	}

	lastDepositAtVal, err := get("last_deposit_at")
	if err != nil {
		return PoolRecordView{}, false, err
	}
	lastDepositAt, err := DecodeScUint64(lastDepositAtVal)
	if err != nil {
		return PoolRecordView{}, false, fmt.Errorf("stellarx: PoolRecord.last_deposit_at: %w", err)
	}

	return PoolRecordView{Token: token, Amount: amount, LastDepositAt: lastDepositAt}, true, nil
}

// decodeUnitEnum decodes a Rust all-unit-variant #[contracttype] enum
// (e.g. ChequeState { Funded, Claimed, Refunded, Collected, Bounced }),
// which soroban-sdk encodes as a bare ScVal symbol matching the variant
// name. Defensively also accepts a one-element ScVec of that symbol,
// since this exact encoding has not been verified against a live network
// (SERVICE.md #2's caveat applies here too).
func decodeUnitEnum(val xdr.ScVal) (string, error) {
	if sym, err := DecodeScSymbol(val); err == nil {
		return sym, nil
	}
	if vec, ok := val.GetVec(); ok && vec != nil && len(*vec) == 1 {
		return DecodeScSymbol((*vec)[0])
	}
	return "", fmt.Errorf("stellarx: expected a unit-enum ScVal (symbol or 1-element vec), got %s", val.Type)
}
