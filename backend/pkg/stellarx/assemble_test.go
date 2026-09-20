package stellarx

import (
	"context"
	"testing"

	"github.com/stellar/go-stellar-sdk/keypair"
	"github.com/stellar/go-stellar-sdk/xdr"
)

// authEntryFixture builds a minimal, structurally valid
// SorobanAuthorizationEntry (source-account credentials, no sub-invocations)
// and returns its base64 XDR — enough for AssembleInvocation to decode and
// attach, without needing a real simulated invocation tree.
func authEntryFixture(t *testing.T) string {
	t.Helper()
	var cid xdr.ContractId
	entry := xdr.SorobanAuthorizationEntry{
		Credentials: xdr.SorobanCredentials{
			Type: xdr.SorobanCredentialsTypeSorobanCredentialsSourceAccount,
		},
		RootInvocation: xdr.SorobanAuthorizedInvocation{
			Function: xdr.SorobanAuthorizedFunction{
				Type: xdr.SorobanAuthorizedFunctionTypeSorobanAuthorizedFunctionTypeContractFn,
				ContractFn: &xdr.InvokeContractArgs{
					ContractAddress: xdr.ScAddress{Type: xdr.ScAddressTypeScAddressTypeContract, ContractId: &cid},
					FunctionName:    "deposit",
				},
			},
		},
	}
	b64, err := xdr.MarshalBase64(entry)
	if err != nil {
		t.Fatalf("marshal auth entry fixture: %v", err)
	}
	return b64
}

// TestAssembleInvocation_AttachesSimulatedAuth covers the pool/cheque
// deposit-withdraw-lock-claim path: the invoked contract function calls
// require_auth on one of its own arguments (not a pre-signed force_collect
// entry), so recording-mode simulation is the only source of the auth
// entry the chain will actually require. Before this test's fix,
// AssembleInvocation discarded SimulationResult.AuthXDR entirely, leaving
// op.Auth empty — soroban-rpc's recording simulation still reports success
// in that case (it is busy *producing* the auth requirement, not
// enforcing it), so the failure only surfaced later, at submit time, as
// Error(Auth, InvalidAction).
func TestAssembleInvocation_AttachesSimulatedAuth(t *testing.T) {
	kp, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	contractAddr := contractAddressFixture(t)
	ownerArg, err := ScAddress(kp.Address())
	if err != nil {
		t.Fatal(err)
	}
	op, err := InvokeContract(contractAddr, kp.Address(), "deposit", ownerArg)
	if err != nil {
		t.Fatal(err)
	}

	wantAuth := authEntryFixture(t)
	simulate := func(ctx context.Context, unsignedXDR string) (SimulationResult, error) {
		return SimulationResult{
			TransactionDataXDR: emptySorobanTransactionDataFixture(t),
			AuthXDR:            []string{wantAuth},
		}, nil
	}

	xdrStr, err := AssembleInvocation(context.Background(), simulate, "Test SDF Network ; September 2015", kp.Address(), 1, op)
	if err != nil {
		t.Fatalf("AssembleInvocation: %v", err)
	}
	if len(op.Auth) != 1 {
		t.Fatalf("expected simulated auth entry to be attached to op.Auth, got %d entries", len(op.Auth))
	}
	gotAuth, err := xdr.MarshalBase64(op.Auth[0])
	if err != nil {
		t.Fatal(err)
	}
	if gotAuth != wantAuth {
		t.Fatalf("attached auth entry mismatch:\ngot:  %s\nwant: %s", gotAuth, wantAuth)
	}
	if xdrStr == "" {
		t.Fatal("expected a non-empty assembled transaction XDR")
	}
}

// TestAssembleInvocation_PreservesPreAttachedAuth covers force_collect: the
// device pre-signs the sender's authorization entry (AttachAuthEntry, called
// before AssembleInvocation), and that entry — not anything recording-mode
// simulation might separately report for the receiver's own call — must be
// what ends up in the final transaction.
func TestAssembleInvocation_PreservesPreAttachedAuth(t *testing.T) {
	kp, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	contractAddr := contractAddressFixture(t)
	op, err := InvokeContract(contractAddr, kp.Address(), "force_collect")
	if err != nil {
		t.Fatal(err)
	}

	preAttached := authEntryFixture(t)
	var preAttachedEntry xdr.SorobanAuthorizationEntry
	if err := xdr.SafeUnmarshalBase64(preAttached, &preAttachedEntry); err != nil {
		t.Fatal(err)
	}
	op.Auth = []xdr.SorobanAuthorizationEntry{preAttachedEntry}

	simulate := func(ctx context.Context, unsignedXDR string) (SimulationResult, error) {
		return SimulationResult{
			TransactionDataXDR: emptySorobanTransactionDataFixture(t),
			AuthXDR:            []string{authEntryFixture(t)}, // a different entry — must be ignored
		}, nil
	}

	if _, err := AssembleInvocation(context.Background(), simulate, "Test SDF Network ; September 2015", kp.Address(), 1, op); err != nil {
		t.Fatalf("AssembleInvocation: %v", err)
	}
	if len(op.Auth) != 1 {
		t.Fatalf("expected exactly the pre-attached auth entry to survive, got %d entries", len(op.Auth))
	}
	gotAuth, err := xdr.MarshalBase64(op.Auth[0])
	if err != nil {
		t.Fatal(err)
	}
	if gotAuth != preAttached {
		t.Fatal("pre-attached force_collect auth entry was overwritten by simulated auth")
	}
}

func emptySorobanTransactionDataFixture(t *testing.T) string {
	t.Helper()
	b64, err := xdr.MarshalBase64(xdr.SorobanTransactionData{
		Resources: xdr.SorobanResources{
			Footprint: xdr.LedgerFootprint{},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return b64
}
