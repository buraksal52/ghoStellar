package stellarx

import (
	"math/big"
	"testing"

	"github.com/stellar/go-stellar-sdk/keypair"
	"github.com/stellar/go-stellar-sdk/xdr"
)

// buildScMap hand-constructs an ScMap the way soroban-sdk's #[contracttype]
// derive is documented to encode a struct — one ScMapEntry per field, key a
// symbol matching the Rust field name. This has NOT been cross-checked
// against a real pay-escrow contract's actual simulateTransaction output
// (see chequerecord.go's package-level caveat) — it locks in the documented
// encoding so a real mismatch shows up as a decode test failure once one
// can be run against testnet, rather than silently.
func buildScMap(t *testing.T, fields map[string]xdr.ScVal) xdr.ScVal {
	t.Helper()
	m := make(xdr.ScMap, 0, len(fields))
	for k, v := range fields {
		sym, err := ScSymbol(k)
		if err != nil {
			t.Fatal(err)
		}
		m = append(m, xdr.ScMapEntry{Key: sym, Val: v})
	}
	val, err := xdr.NewScVal(xdr.ScValTypeScvMap, &m)
	if err != nil {
		t.Fatal(err)
	}
	return val
}

func buildUnitEnum(t *testing.T, variant string) xdr.ScVal {
	t.Helper()
	val, err := ScSymbol(variant)
	if err != nil {
		t.Fatal(err)
	}
	return val
}

func TestDecodeChequeRecord_RoundTrip(t *testing.T) {
	sender, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	receiver, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	token := contractAddressFixture(t)

	senderSc, err := ScAddress(sender.Address())
	if err != nil {
		t.Fatal(err)
	}
	receiverSc, err := ScAddress(receiver.Address())
	if err != nil {
		t.Fatal(err)
	}
	tokenSc, err := ScAddress(token)
	if err != nil {
		t.Fatal(err)
	}
	amountSc, err := ScI128(big.NewInt(105_000_000))
	if err != nil {
		t.Fatal(err)
	}
	expiresAtSc, err := ScUint64(1_800_000_000)
	if err != nil {
		t.Fatal(err)
	}

	record := buildScMap(t, map[string]xdr.ScVal{
		"sender":     senderSc,
		"receiver":   receiverSc,
		"token":      tokenSc,
		"amount":     amountSc,
		"expires_at": expiresAtSc,
		"state":      buildUnitEnum(t, "Funded"),
	})
	// Option<ChequeRecord>::Some(record) — a bare present value, per
	// DecodeOptional's contract (anything that isn't ScvVoid is "present").
	view, present, err := DecodeChequeRecord(record)
	if err != nil {
		t.Fatalf("DecodeChequeRecord: %v", err)
	}
	if !present {
		t.Fatal("expected present=true")
	}
	if view.Sender != sender.Address() {
		t.Errorf("Sender = %q, want %q", view.Sender, sender.Address())
	}
	if view.Receiver != receiver.Address() {
		t.Errorf("Receiver = %q, want %q", view.Receiver, receiver.Address())
	}
	if view.Token != token {
		t.Errorf("Token = %q, want %q", view.Token, token)
	}
	if view.Amount.Cmp(big.NewInt(105_000_000)) != 0 {
		t.Errorf("Amount = %s, want 105000000", view.Amount)
	}
	if view.ExpiresAt != 1_800_000_000 {
		t.Errorf("ExpiresAt = %d, want 1800000000", view.ExpiresAt)
	}
	if view.State != "Funded" {
		t.Errorf("State = %q, want Funded", view.State)
	}
}

func TestDecodeChequeRecord_NoneIsAbsent(t *testing.T) {
	none := xdr.ScVal{Type: xdr.ScValTypeScvVoid}
	view, present, err := DecodeChequeRecord(none)
	if err != nil {
		t.Fatalf("DecodeChequeRecord(None): %v", err)
	}
	if present {
		t.Error("expected present=false for Option::None")
	}
	if view != (ChequeRecordView{}) {
		t.Errorf("expected zero-value view, got %+v", view)
	}
}

func TestDecodeChequeRecord_MissingFieldErrors(t *testing.T) {
	incomplete := buildScMap(t, map[string]xdr.ScVal{
		"sender": buildUnitEnum(t, "irrelevant"), // wrong type on purpose, but "amount" etc. are simply absent
	})
	if _, _, err := DecodeChequeRecord(incomplete); err == nil {
		t.Fatal("expected an error for a map missing required fields")
	}
}

func TestDecodePoolRecord_RoundTrip(t *testing.T) {
	token := contractAddressFixture(t)
	tokenSc, err := ScAddress(token)
	if err != nil {
		t.Fatal(err)
	}
	amountSc, err := ScI128(big.NewInt(200_000_000))
	if err != nil {
		t.Fatal(err)
	}
	lastDepositSc, err := ScUint64(1_700_000_000)
	if err != nil {
		t.Fatal(err)
	}

	record := buildScMap(t, map[string]xdr.ScVal{
		"token":           tokenSc,
		"amount":          amountSc,
		"last_deposit_at": lastDepositSc,
	})
	view, present, err := DecodePoolRecord(record)
	if err != nil {
		t.Fatalf("DecodePoolRecord: %v", err)
	}
	if !present {
		t.Fatal("expected present=true")
	}
	if view.Token != token {
		t.Errorf("Token = %q, want %q", view.Token, token)
	}
	if view.Amount.Cmp(big.NewInt(200_000_000)) != 0 {
		t.Errorf("Amount = %s, want 200000000", view.Amount)
	}
	if view.LastDepositAt != 1_700_000_000 {
		t.Errorf("LastDepositAt = %d, want 1700000000", view.LastDepositAt)
	}
}

func TestDecodePoolRecord_NoneIsAbsent(t *testing.T) {
	none := xdr.ScVal{Type: xdr.ScValTypeScvVoid}
	_, present, err := DecodePoolRecord(none)
	if err != nil {
		t.Fatalf("DecodePoolRecord(None): %v", err)
	}
	if present {
		t.Error("expected present=false for Option::None")
	}
}

func TestDecodeScI128_NegativeRoundTrip(t *testing.T) {
	want := big.NewInt(-42)
	val, err := ScI128(want)
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeScI128(val)
	if err != nil {
		t.Fatal(err)
	}
	if got.Cmp(want) != 0 {
		t.Errorf("got %s, want %s", got, want)
	}
}

func TestDecodeScAddress_WrongTypeErrors(t *testing.T) {
	notAnAddress, err := ScUint64(42)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeScAddress(notAnAddress); err == nil {
		t.Fatal("expected an error decoding a non-address ScVal as an address")
	}
}
