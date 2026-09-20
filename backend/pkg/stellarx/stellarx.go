// Package stellarx holds the low-level Stellar/Soroban XDR construction
// helpers shared by every service that produces unsigned transactions:
// building ScVal arguments for pay-escrow invocations, addresses, and
// encoding/decoding transaction envelopes. No service other than
// pay-tx-service ever signs or submits — everything here stops at
// "unsigned XDR ready to hand to the device". See
// docs/reference/platform/architecture.md §1 (non-custodial) and §4.
package stellarx

import (
	"crypto/sha256"
	"fmt"
	"math/big"

	"github.com/stellar/go-stellar-sdk/keypair"
	"github.com/stellar/go-stellar-sdk/strkey"
	"github.com/stellar/go-stellar-sdk/txnbuild"
	"github.com/stellar/go-stellar-sdk/xdr"
)

func sha256Hash(b []byte) [32]byte {
	return sha256.Sum256(b)
}

// TestNetworkPassphrase is the default every service falls back to when
// NETWORK_PASSPHRASE is unset. Kept in one place so the six cmd/*/main.go
// call sites can't drift from each other.
const TestNetworkPassphrase = "Test SDF Network ; September 2015"

// IsValidAccountAddress reports whether s is a well-formed "G..." account
// strkey. Used to validate cheque receiver addresses (A4) before ever
// touching the chain.
func IsValidAccountAddress(s string) bool {
	return strkey.IsValidEd25519PublicKey(s)
}

// IsValidContractAddress reports whether s is a well-formed "C..." contract
// strkey.
func IsValidContractAddress(s string) bool {
	_, err := strkey.Decode(strkey.VersionByteContract, s)
	return err == nil
}

// ScAddress builds an xdr.ScVal holding an SCAddress, accepting either a
// "G..." account or a "C..." contract strkey.
func ScAddress(address string) (xdr.ScVal, error) {
	switch {
	case strkey.IsValidEd25519PublicKey(address):
		accountID, err := xdr.AddressToAccountId(address)
		if err != nil {
			return xdr.ScVal{}, fmt.Errorf("stellarx: bad account address %q: %w", address, err)
		}
		sc := xdr.ScAddress{Type: xdr.ScAddressTypeScAddressTypeAccount, AccountId: &accountID}
		val, err := xdr.NewScVal(xdr.ScValTypeScvAddress, sc)
		return val, err
	default:
		decoded, err := strkey.Decode(strkey.VersionByteContract, address)
		if err != nil {
			return xdr.ScVal{}, fmt.Errorf("stellarx: not a valid account or contract address: %q", address)
		}
		var cid xdr.ContractId
		copy(cid[:], decoded)
		sc := xdr.ScAddress{Type: xdr.ScAddressTypeScAddressTypeContract, ContractId: &cid}
		val, err := xdr.NewScVal(xdr.ScValTypeScvAddress, sc)
		return val, err
	}
}

// ScI128 encodes raw (a two's-complement signed magnitude, as carried by
// money.Amount.Raw) as an Soroban i128 ScVal.
func ScI128(raw *big.Int) (xdr.ScVal, error) {
	if raw == nil {
		raw = big.NewInt(0)
	}
	unsigned := new(big.Int).Set(raw)
	if raw.Sign() < 0 {
		twoPow128 := new(big.Int).Lsh(big.NewInt(1), 128)
		unsigned.Add(raw, twoPow128)
	}
	mask64 := new(big.Int).SetUint64(^uint64(0))
	lo := new(big.Int).And(unsigned, mask64).Uint64()
	hiBig := new(big.Int).Rsh(unsigned, 64)
	hiBig.And(hiBig, mask64)
	hi := int64(hiBig.Uint64())
	parts := xdr.Int128Parts{Hi: xdr.Int64(hi), Lo: xdr.Uint64(lo)}
	return xdr.NewScVal(xdr.ScValTypeScvI128, parts)
}

// ScSymbol encodes s (at most 32 ASCII characters, Soroban's symbol limit)
// as an ScVal symbol — used for the pay-escrow function-name-shaped
// arguments and short enum-like tags.
func ScSymbol(s string) (xdr.ScVal, error) {
	if len(s) > 32 {
		return xdr.ScVal{}, fmt.Errorf("stellarx: symbol %q exceeds 32 chars", s)
	}
	sym := xdr.ScSymbol(s)
	return xdr.NewScVal(xdr.ScValTypeScvSymbol, sym)
}

// ScBytes encodes b as an ScVal bytes value — used for the cheque id (a
// ULID, 16 raw bytes) passed to lock/claim/refund/force_collect.
func ScBytes(b []byte) (xdr.ScVal, error) {
	sb := xdr.ScBytes(b)
	return xdr.NewScVal(xdr.ScValTypeScvBytes, sb)
}

// ScUint64 encodes v as an ScVal u64 — used for ledger-timestamp arguments
// such as a cheque's expires_at.
func ScUint64(v uint64) (xdr.ScVal, error) {
	return xdr.NewScVal(xdr.ScValTypeScvU64, xdr.Uint64(v))
}

// ---- decode helpers ---------------------------------------------------
//
// Everything above this point only ENCODES ScVals (Go value -> XDR, for
// building an invocation's arguments). These decode the other direction —
// XDR -> Go value, for reading a contract's own state back out of a
// simulateTransaction result (e.g. `get_cheque`/`get_pool`). Needed to
// close SERVICE.md #1 (an independent, chain-derived cross-check for
// /sync instead of trusting the local Postgres cache alone).
//
// CAVEAT (ties to SERVICE.md #2's same caveat): the exact ScVal shape a
// real deployed pay-escrow contract emits for its `#[contracttype]`
// structs and unit-variant enums has not been exercised against a live
// network from this codebase. These decoders follow soroban-sdk's
// documented encoding (struct -> ScMap keyed by field name as an
// ScSymbol; an all-unit-variant enum -> a bare ScSymbol matching the
// variant name) but should be verified against a real `simulateTransaction`
// response before being trusted as a sole source of truth.

// DecodeScAddress decodes an ScVal holding an SCAddress back into its "G..."
// account or "C..." contract strkey.
func DecodeScAddress(val xdr.ScVal) (string, error) {
	addr, ok := val.GetAddress()
	if !ok {
		return "", fmt.Errorf("stellarx: expected an address ScVal, got %s", val.Type)
	}
	return addr.String()
}

// DecodeScI128 decodes an ScVal holding an i128 back into a signed
// *big.Int — the inverse of ScI128.
func DecodeScI128(val xdr.ScVal) (*big.Int, error) {
	parts, ok := val.GetI128()
	if !ok {
		return nil, fmt.Errorf("stellarx: expected an i128 ScVal, got %s", val.Type)
	}
	raw := new(big.Int).Lsh(new(big.Int).SetUint64(uint64(parts.Hi)), 64)
	raw.Or(raw, new(big.Int).SetUint64(uint64(parts.Lo)))
	if parts.Hi < 0 {
		twoPow128 := new(big.Int).Lsh(big.NewInt(1), 128)
		raw.Sub(raw, twoPow128)
	}
	return raw, nil
}

// DecodeScUint64 decodes an ScVal holding a u64.
func DecodeScUint64(val xdr.ScVal) (uint64, error) {
	v, ok := val.GetU64()
	if !ok {
		return 0, fmt.Errorf("stellarx: expected a u64 ScVal, got %s", val.Type)
	}
	return uint64(v), nil
}

// DecodeScSymbol decodes an ScVal holding a symbol back into a plain
// string — used both for map keys and for a unit-variant enum's tag.
func DecodeScSymbol(val xdr.ScVal) (string, error) {
	sym, ok := val.GetSym()
	if !ok {
		return "", fmt.Errorf("stellarx: expected a symbol ScVal, got %s", val.Type)
	}
	return string(sym), nil
}

// DecodeOptional reports whether val represents Soroban's Option::Some
// (present=true, val itself is the inner value) or Option::None
// (present=false — encoded as ScvVoid).
func DecodeOptional(val xdr.ScVal) (present bool, inner xdr.ScVal) {
	if val.Type == xdr.ScValTypeScvVoid {
		return false, xdr.ScVal{}
	}
	return true, val
}

// scMapGet linearly scans an ScMap for the entry whose key decodes to
// name. soroban-sdk does not guarantee any particular field order for a
// struct's map encoding, so this never assumes one.
func scMapGet(m xdr.ScMap, name string) (xdr.ScVal, bool) {
	for _, entry := range m {
		key, err := DecodeScSymbol(entry.Key)
		if err == nil && key == name {
			return entry.Val, true
		}
	}
	return xdr.ScVal{}, false
}

// decodeMap extracts val's ScMap, erroring with a field-name-free message
// suitable for wrapping by a specific struct decoder.
func decodeMap(val xdr.ScVal) (xdr.ScMap, error) {
	m, ok := val.GetMap()
	if !ok || m == nil {
		return nil, fmt.Errorf("stellarx: expected a map ScVal, got %s", val.Type)
	}
	return *m, nil
}

// InvokeContract builds an unsigned InvokeHostFunction operation calling
// function on the contract at contractAddress, with sourceAccount as the
// operation's source (and therefore the account whose auth entry is
// required unless the caller supplies its own via txnbuild.Transaction's
// SorobanAuth). Callers still need to wrap the returned operation in a
// txnbuild.Transaction with a fresh sequence number (fetched from
// pay-chain-gateway) and simulate it via Soroban RPC to size fees/footprint
// before returning the XDR to a device for signing.
func InvokeContract(contractAddress, sourceAccount, function string, args ...xdr.ScVal) (*txnbuild.InvokeHostFunction, error) {
	decoded, err := strkey.Decode(strkey.VersionByteContract, contractAddress)
	if err != nil {
		return nil, fmt.Errorf("stellarx: bad contract address %q: %w", contractAddress, err)
	}
	var cid xdr.ContractId
	copy(cid[:], decoded)

	scAddr := xdr.ScAddress{Type: xdr.ScAddressTypeScAddressTypeContract, ContractId: &cid}
	invoke := xdr.InvokeContractArgs{
		ContractAddress: scAddr,
		FunctionName:    xdr.ScSymbol(function),
		Args:            args,
	}
	hf, err := xdr.NewHostFunction(xdr.HostFunctionTypeHostFunctionTypeInvokeContract, invoke)
	if err != nil {
		return nil, err
	}
	return &txnbuild.InvokeHostFunction{
		HostFunction:  hf,
		SourceAccount: sourceAccount,
	}, nil
}

// BuildForceCollectAuthEntry builds the UNSIGNED SorobanAuthorizationEntry
// the sender must sign when a cheque is written, so the receiver can later
// submit `force_collect` on the sender's behalf if the sender never funds
// it (docs/reference/platform/architecture.md's twin, the p2p doc §5, and
// the plan's "Kritik Mimari Karar"). The device signs the returned entry's
// payload hash (per CAP-46-11 / the SorobanAuthorization preimage below)
// and fills in Credentials.Address.Signature — this function only builds
// the entry and computes that hash; it never signs anything itself
// (non-custodial: no service but the device ever holds a signing key for a
// user's own account).
//
// expirationLedger is a LEDGER SEQUENCE (not a unix timestamp) — Soroban's
// own auth-entry expiry field, chosen so it is at or before the cheque's
// expires_at converted to an approximate ledger height.
//
// NOTE: this XDR shape follows the documented CAP-46-11 authorization
// preimage exactly, but — like any Soroban auth-entry construction — it
// has not been exercised against a live network in this codebase yet.
// Verify the resulting entry actually satisfies `sender.require_auth()` in
// pay-escrow's force_collect against testnet before relying on it (see
// contracts/soroban/pay-escrow/README.md and the plan's build-order notes).
func BuildForceCollectAuthEntry(
	networkPassphrase string,
	contractAddress string,
	sender, receiver, token string,
	amount *big.Int,
	chequeID []byte,
	expiresAtUnix uint64,
	expirationLedger uint32,
	nonce int64,
) ([]byte, []byte, error) {
	senderSc, err := ScAddress(sender)
	if err != nil {
		return nil, nil, err
	}
	receiverSc, err := ScAddress(receiver)
	if err != nil {
		return nil, nil, err
	}
	tokenSc, err := ScAddress(token)
	if err != nil {
		return nil, nil, err
	}
	amountSc, err := ScI128(amount)
	if err != nil {
		return nil, nil, err
	}
	chequeIDSc, err := ScBytes(chequeID)
	if err != nil {
		return nil, nil, err
	}
	expiresAtSc, err := ScUint64(expiresAtUnix)
	if err != nil {
		return nil, nil, err
	}

	decoded, err := strkey.Decode(strkey.VersionByteContract, contractAddress)
	if err != nil {
		return nil, nil, fmt.Errorf("stellarx: bad contract address %q: %w", contractAddress, err)
	}
	var cid xdr.ContractId
	copy(cid[:], decoded)
	contractSc := xdr.ScAddress{Type: xdr.ScAddressTypeScAddressTypeContract, ContractId: &cid}

	invokeArgs := xdr.InvokeContractArgs{
		ContractAddress: contractSc,
		FunctionName:    xdr.ScSymbol("force_collect"),
		// Argument order MUST exactly match pay-escrow::force_collect's
		// signature: sender, cheque_id, receiver, token, amount, expires_at.
		Args: []xdr.ScVal{senderSc, chequeIDSc, receiverSc, tokenSc, amountSc, expiresAtSc},
	}
	function, err := xdr.NewSorobanAuthorizedFunction(xdr.SorobanAuthorizedFunctionTypeSorobanAuthorizedFunctionTypeContractFn, invokeArgs)
	if err != nil {
		return nil, nil, err
	}
	invocation := xdr.SorobanAuthorizedInvocation{Function: function}

	networkID := sha256Hash([]byte(networkPassphrase))
	preimage := xdr.HashIdPreimageSorobanAuthorization{
		NetworkId:                 xdr.Hash(networkID),
		Nonce:                     xdr.Int64(nonce),
		SignatureExpirationLedger: xdr.Uint32(expirationLedger),
		Invocation:                invocation,
	}
	hashPreimage, err := xdr.NewHashIdPreimage(xdr.EnvelopeTypeEnvelopeTypeSorobanAuthorization, preimage)
	if err != nil {
		return nil, nil, err
	}
	preimageBytes, err := hashPreimage.MarshalBinary()
	if err != nil {
		return nil, nil, err
	}
	payloadHashArr := sha256Hash(preimageBytes)
	payloadHash := payloadHashArr[:]

	credentials := xdr.SorobanCredentials{
		Type: xdr.SorobanCredentialsTypeSorobanCredentialsAddress,
		Address: &xdr.SorobanAddressCredentials{
			Address:                   senderSc.MustAddress(),
			Nonce:                     xdr.Int64(nonce),
			SignatureExpirationLedger: xdr.Uint32(expirationLedger),
			Signature:                 xdr.ScVal{Type: xdr.ScValTypeScvVoid}, // filled in by the device once signed
		},
	}
	entry := xdr.SorobanAuthorizationEntry{Credentials: credentials, RootInvocation: invocation}
	entryBytes, err := entry.MarshalBinary()
	if err != nil {
		return nil, nil, err
	}
	return entryBytes, payloadHash, nil
}

// AttachAuthEntry decodes a signed SorobanAuthorizationEntry (as produced by
// BuildForceCollectAuthEntry and then signed by the sender's device) and
// attaches it to op — this is how a `force_collect` transaction, submitted
// and paid for by the receiver, carries the sender's own pre-authorization
// for the call.
func AttachAuthEntry(op *txnbuild.InvokeHostFunction, signedEntryXDR []byte) error {
	var entry xdr.SorobanAuthorizationEntry
	if err := entry.UnmarshalBinary(signedEntryXDR); err != nil {
		return fmt.Errorf("stellarx: decode signed auth entry: %w", err)
	}
	op.Auth = append(op.Auth, entry)
	return nil
}

// KeypairFromSeed loads an ed25519 keypair from its "S..." strkey seed. Used
// only by pay-scheduler-service's fee-paying keeper account (which pays
// network fees for permissionless refund() calls and never authorizes
// moving a user's funds — see docs/reference/platform/anchor-entegrasyonu.md
// "Keeper hesabı" for the exact boundary).
func KeypairFromSeed(seed string) (*keypair.Full, error) {
	return keypair.ParseFull(seed)
}

// SignTransactionXDR decodes an unsigned transaction envelope (base64),
// signs it with kp, and re-encodes it. Used only by pay-scheduler-service's
// keeper key — every user-facing signature happens on the device, never
// here (non-custodial, architecture.md §1 rule 5).
func SignTransactionXDR(unsignedXDR, networkPassphrase string, kp *keypair.Full) (string, error) {
	tx, err := txnbuild.TransactionFromXDR(unsignedXDR)
	if err != nil {
		return "", fmt.Errorf("stellarx: decode tx: %w", err)
	}
	simple, ok := tx.Transaction()
	if !ok {
		return "", fmt.Errorf("stellarx: expected a simple (non-fee-bump) transaction")
	}
	signed, err := simple.Sign(networkPassphrase, kp)
	if err != nil {
		return "", fmt.Errorf("stellarx: sign tx: %w", err)
	}
	return signed.Base64()
}
