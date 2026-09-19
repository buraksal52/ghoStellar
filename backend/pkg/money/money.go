// Package money provides the single amount type shared by every De-Fi
// service. Money is never represented as float64 anywhere in this codebase.
//
// Stellar classic assets use int64 stroops (7 decimals); Soroban assets use
// i128 with a contract-defined decimal count. Amount unifies both behind a
// *big.Int plus an explicit decimal count, and always crosses API
// boundaries as a decimal string.
//
// See docs/reference/platform/architecture.txt §7. This file's behavior
// must stay in lockstep with the TS twin, apps/packages/money/src/index.ts;
// services/pkg/money/testdata/vectors.json is the shared proof of that.
package money

import (
	"errors"
	"fmt"
	"math/big"
	"regexp"
)

// AssetID identifies either a Stellar classic asset (Code + Issuer) or a
// Soroban contract asset (ContractID). Exactly one form is populated.
type AssetID struct {
	Code       string // classic asset code, e.g. "USDC"; empty for native XLM use "XLM"
	Issuer     string // classic asset issuer account; empty for native XLM
	ContractID string // Soroban contract address; empty for classic assets
}

// Amount is a fixed-point quantity: Raw * 10^-Decimals units of Asset.
// Raw must never be nil in a valid Amount.
type Amount struct {
	Raw      *big.Int
	Decimals uint8
	Asset    AssetID
}

// Zero returns the zero amount for the given asset and decimal count.
func Zero(asset AssetID, decimals uint8) Amount {
	return Amount{Raw: big.NewInt(0), Decimals: decimals, Asset: asset}
}

// ErrNotImplemented is returned by functions that are intentionally left as
// skeleton stubs pending the real fixed-point implementation.
var ErrNotImplemented = errors.New("money: not implemented")

// String renders the amount as a decimal string, e.g. "1234.5678900". This
// is the only representation permitted to cross an API boundary — JSON
// numbers are never used for money.
//
// This is a pure rendering of Raw/Decimals; it does not itself round.
// Callers that need directional rounding (architecture.txt §7: amountOut
// rounds down, amountIn rounds up) must round Raw before constructing the
// Amount — String always renders the exact value it holds.
func (a Amount) String() string {
	raw := a.Raw
	if raw == nil {
		raw = big.NewInt(0)
	}
	negative := raw.Sign() < 0
	abs := new(big.Int).Abs(raw)
	s := abs.String()
	decimals := int(a.Decimals)
	if len(s) < decimals+1 {
		s = zeroPad(s, decimals+1)
	}
	whole := s[:len(s)-decimals]
	if whole == "" {
		whole = "0"
	}
	out := whole
	if decimals > 0 {
		out += "." + s[len(s)-decimals:]
	}
	if negative {
		out = "-" + out
	}
	return out
}

func zeroPad(s string, width int) string {
	for len(s) < width {
		s = "0" + s
	}
	return s
}

var decimalStringRe = regexp.MustCompile(`^(-?)(\d+)(?:\.(\d+))?$`)

// ParseAmount parses a decimal string produced by Amount.String back into
// an Amount for the given asset/decimals. It rejects scientific notation
// and any fractional part with more digits than `decimals` — a caller-
// supplied amount is never silently rounded or truncated.
func ParseAmount(s string, asset AssetID, decimals uint8) (Amount, error) {
	m := decimalStringRe.FindStringSubmatch(s)
	if m == nil {
		return Amount{}, fmt.Errorf("money: not a decimal string: %q", s)
	}
	sign, wholeStr, fracStr := m[1], m[2], m[3]
	if len(fracStr) > int(decimals) {
		return Amount{}, fmt.Errorf("money: %q has more than %d fractional digits", s, decimals)
	}
	fracStr = fracStr + zerosString(int(decimals)-len(fracStr))

	raw, ok := new(big.Int).SetString(wholeStr+fracStr, 10)
	if !ok {
		return Amount{}, fmt.Errorf("money: not a decimal string: %q", s)
	}
	if sign == "-" {
		raw.Neg(raw)
	}
	return Amount{Raw: raw, Decimals: decimals, Asset: asset}, nil
}

func zerosString(n int) string {
	if n <= 0 {
		return ""
	}
	b := make([]byte, n)
	for i := range b {
		b[i] = '0'
	}
	return string(b)
}

// FromStroops builds a classic-asset Amount from a raw int64 stroop count
// (7 decimals fixed).
func FromStroops(stroops int64, asset AssetID) Amount {
	return Amount{Raw: big.NewInt(stroops), Decimals: 7, Asset: asset}
}

// FromI128 builds a Soroban Amount from raw hi/lo i128 halves (as carried
// by xdr.Int128Parts / scValToNative on the TS side: hi is the signed high
// 64 bits, lo is the unsigned low 64 bits of a two's-complement i128) and
// the contract's declared decimal count.
func FromI128(hi int64, lo uint64, decimals uint8, asset AssetID) (Amount, error) {
	// Assemble the unsigned 128-bit magnitude bit pattern first: hi<<64 | lo,
	// interpreting hi's bits as unsigned for the shift, then reinterpret the
	// full 128-bit pattern as two's-complement signed.
	raw := new(big.Int).Lsh(new(big.Int).SetUint64(uint64(hi)), 64)
	raw.Or(raw, new(big.Int).SetUint64(lo))

	if hi < 0 {
		// raw currently holds the unsigned 128-bit bit pattern; convert from
		// two's-complement to a negative *big.Int by subtracting 2^128.
		twoPow128 := new(big.Int).Lsh(big.NewInt(1), 128)
		raw.Sub(raw, twoPow128)
	}

	return Amount{Raw: raw, Decimals: decimals, Asset: asset}, nil
}
