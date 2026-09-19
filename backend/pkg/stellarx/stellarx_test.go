package stellarx

import (
	"math/big"
	"strings"
	"testing"

	"github.com/stellar/go-stellar-sdk/keypair"
	"github.com/stellar/go-stellar-sdk/strkey"
	"github.com/stellar/go-stellar-sdk/xdr"
)

func TestScAddressAccount(t *testing.T) {
	kp, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	val, err := ScAddress(kp.Address())
	if err != nil {
		t.Fatal(err)
	}
	addr, ok := val.GetAddress()
	if !ok {
		t.Fatal("expected an address ScVal")
	}
	s, err := addr.String()
	if err != nil {
		t.Fatal(err)
	}
	if s != kp.Address() {
		t.Fatalf("got %q, want %q", s, kp.Address())
	}
}

func TestScI128RoundTrip(t *testing.T) {
	cases := []string{"0", "1", "-1", "18446744073709551615", "-100", "170141183460469231731687303715884105727"}
	for _, c := range cases {
		want, ok := new(big.Int).SetString(c, 10)
		if !ok {
			t.Fatalf("bad test fixture %q", c)
		}
		val, err := ScI128(want)
		if err != nil {
			t.Fatalf("ScI128(%s): %v", c, err)
		}
		parts, ok := val.GetI128()
		if !ok {
			t.Fatalf("ScI128(%s): not an i128 ScVal", c)
		}
		got := bigIntFromInt128(int64(parts.Hi), uint64(parts.Lo))
		if got.Cmp(want) != 0 {
			t.Fatalf("ScI128(%s) round-trip: got %s", c, got.String())
		}
	}
}

func bigIntFromInt128(hi int64, lo uint64) *big.Int {
	raw := new(big.Int).Lsh(new(big.Int).SetUint64(uint64(hi)), 64)
	raw.Or(raw, new(big.Int).SetUint64(lo))
	if hi < 0 {
		twoPow128 := new(big.Int).Lsh(big.NewInt(1), 128)
		raw.Sub(raw, twoPow128)
	}
	return raw
}

func TestScSymbolTooLong(t *testing.T) {
	long := strings.Repeat("a", 33)
	if _, err := ScSymbol(long); err == nil {
		t.Fatal("expected error for symbol over 32 chars")
	}
}

func TestInvokeContractBuilds(t *testing.T) {
	kp, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	// A syntactically valid contract strkey is required; build one from 32
	// zero bytes rather than hand-writing checksum bytes.
	addr := contractAddressFixture(t)
	amt, _ := ScI128(big.NewInt(500))
	op, err := InvokeContract(addr, kp.Address(), "claim", amt)
	if err != nil {
		t.Fatal(err)
	}
	if op.SourceAccount != kp.Address() {
		t.Fatalf("source account mismatch: %s", op.SourceAccount)
	}
	invoke, ok := op.HostFunction.GetInvokeContract()
	if !ok {
		t.Fatal("expected an InvokeContract host function")
	}
	if string(invoke.FunctionName) != "claim" {
		t.Fatalf("function name mismatch: %s", invoke.FunctionName)
	}
}

func TestBuildForceCollectAuthEntryProducesValidXDR(t *testing.T) {
	sender, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	receiver, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	token := contractAddressFixture(t)
	contract := contractAddressFixture(t)
	chequeID := make([]byte, 16)

	entryBytes, payloadHash, err := BuildForceCollectAuthEntry(
		"Test SDF Network ; September 2015",
		contract,
		sender.Address(), receiver.Address(), token,
		big.NewInt(500),
		chequeID,
		1_800_000_000,
		1_000_000,
		42,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(payloadHash) != 32 {
		t.Fatalf("expected a 32-byte sha256 payload hash, got %d bytes", len(payloadHash))
	}

	var entry xdr.SorobanAuthorizationEntry
	if err := entry.UnmarshalBinary(entryBytes); err != nil {
		t.Fatalf("entry does not round-trip through XDR: %v", err)
	}
	if entry.Credentials.Type != xdr.SorobanCredentialsTypeSorobanCredentialsAddress {
		t.Fatalf("expected address credentials, got %v", entry.Credentials.Type)
	}
	if entry.Credentials.Address.Nonce != 42 {
		t.Fatalf("nonce mismatch: %d", entry.Credentials.Address.Nonce)
	}
	fn, ok := entry.RootInvocation.Function.GetContractFn()
	if !ok {
		t.Fatal("expected a ContractFn invocation")
	}
	if string(fn.FunctionName) != "force_collect" {
		t.Fatalf("function name mismatch: %s", fn.FunctionName)
	}
	if len(fn.Args) != 6 {
		t.Fatalf("expected 6 args (sender, cheque_id, receiver, token, amount, expires_at), got %d", len(fn.Args))
	}
}

func contractAddressFixture(t *testing.T) string {
	t.Helper()
	payload := make([]byte, 32)
	s, err := strkey.Encode(strkey.VersionByteContract, payload)
	if err != nil {
		t.Fatal(err)
	}
	return s
}
