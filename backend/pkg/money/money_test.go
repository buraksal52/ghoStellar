package money

import (
	"encoding/json"
	"os"
	"strconv"
	"testing"
)

// vectors mirrors testdata/vectors.json, the file shared with the TS twin
// (apps/packages/money/src/index.test.ts). Keep both readers in sync — see
// that file's header and the ZK-rail plan's note on cross-language field
// element / serialization drift.
type vectors struct {
	DecimalStringRoundTrip []struct {
		Input    string `json:"input"`
		Decimals uint8  `json:"decimals"`
		Raw      string `json:"raw"`
		Rendered string `json:"rendered"`
	} `json:"decimalStringRoundTrip"`
	ParseAmountRejects []struct {
		Input    string `json:"input"`
		Decimals uint8  `json:"decimals"`
		Reason   string `json:"reason"`
	} `json:"parseAmountRejects"`
	FromI128 []struct {
		Hi       string `json:"hi"`
		Lo       string `json:"lo"`
		Decimals uint8  `json:"decimals"`
		Raw      string `json:"raw"`
		Rendered string `json:"rendered"`
	} `json:"fromI128"`
}

func loadVectors(t *testing.T) vectors {
	t.Helper()
	data, err := os.ReadFile("testdata/vectors.json")
	if err != nil {
		t.Fatalf("reading testdata/vectors.json: %v", err)
	}
	var v vectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatalf("parsing testdata/vectors.json: %v", err)
	}
	return v
}

var testAsset = AssetID{Code: "USDC", Issuer: "GISSUER"}

func TestDecimalStringRoundTrip(t *testing.T) {
	for _, tc := range loadVectors(t).DecimalStringRoundTrip {
		t.Run(tc.Input, func(t *testing.T) {
			a, err := ParseAmount(tc.Input, testAsset, tc.Decimals)
			if err != nil {
				t.Fatalf("ParseAmount(%q): %v", tc.Input, err)
			}
			if got := a.Raw.String(); got != tc.Raw {
				t.Errorf("ParseAmount(%q).Raw = %s, want %s", tc.Input, got, tc.Raw)
			}
			if got := a.String(); got != tc.Rendered {
				t.Errorf("Amount.String() after ParseAmount(%q) = %s, want %s", tc.Input, got, tc.Rendered)
			}
		})
	}
}

func TestParseAmountRejects(t *testing.T) {
	for _, tc := range loadVectors(t).ParseAmountRejects {
		t.Run(tc.Input, func(t *testing.T) {
			if _, err := ParseAmount(tc.Input, testAsset, tc.Decimals); err == nil {
				t.Errorf("ParseAmount(%q) succeeded, want error (%s)", tc.Input, tc.Reason)
			}
		})
	}
}

func TestFromI128(t *testing.T) {
	for _, tc := range loadVectors(t).FromI128 {
		t.Run(tc.Raw, func(t *testing.T) {
			hi, err := strconv.ParseInt(tc.Hi, 10, 64)
			if err != nil {
				t.Fatalf("parsing hi %q: %v", tc.Hi, err)
			}
			lo, err := strconv.ParseUint(tc.Lo, 10, 64)
			if err != nil {
				t.Fatalf("parsing lo %q: %v", tc.Lo, err)
			}
			a, err := FromI128(hi, lo, tc.Decimals, testAsset)
			if err != nil {
				t.Fatalf("FromI128(%d, %d): %v", hi, lo, err)
			}
			if got := a.Raw.String(); got != tc.Raw {
				t.Errorf("FromI128(%d, %d).Raw = %s, want %s", hi, lo, got, tc.Raw)
			}
			if got := a.String(); got != tc.Rendered {
				t.Errorf("FromI128(%d, %d).String() = %s, want %s", hi, lo, got, tc.Rendered)
			}
		})
	}
}

func TestZero(t *testing.T) {
	z := Zero(testAsset, 7)
	if got, want := z.String(), "0.0000000"; got != want {
		t.Errorf("Zero(...).String() = %s, want %s", got, want)
	}
}
