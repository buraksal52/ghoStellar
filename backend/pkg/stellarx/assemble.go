package stellarx

import (
	"context"
	"fmt"

	"github.com/stellar/go-stellar-sdk/txnbuild"
	"github.com/stellar/go-stellar-sdk/xdr"
)

// SimulationResult is the trimmed slice of a simulateTransaction response
// that AssembleInvocation needs: the resource footprint/fee to attach, plus
// (when the invoked function itself calls require_auth on one of its own
// arguments — deposit/withdraw/lock/claim's owner — as opposed to
// force_collect's separately pre-signed entry) the Soroban authorization
// entries recording-mode simulation produced for it.
type SimulationResult struct {
	TransactionDataXDR string
	AuthXDR            []string // base64 SorobanAuthorizationEntry, one per required auth
}

// Simulator is the one thing AssembleInvocation needs from
// pay-chain-gateway: a way to run simulateTransaction. Defined here as a
// function type (not ports.ChainGateway) so this low-level package never
// depends on the higher-level ports package — callers adapt their
// ports.ChainGateway with a one-line closure.
type Simulator func(ctx context.Context, unsignedXDR string) (SimulationResult, error)

// AssembleInvocation builds a submittable-once-signed Soroban transaction
// for a single InvokeHostFunction operation: it simulates once to size the
// resource footprint and fee, attaches the result, and returns the
// unsigned transaction's base64 XDR. sourceAccount is the operation's
// source (whoever needs to sign — the cheque's sender for lock, the
// receiver for claim/force_collect, either for pool ops) and sequence is
// their CURRENT account sequence number (pay-chain-gateway's
// GetAccount().Sequence) — this function increments it itself.
func AssembleInvocation(
	ctx context.Context,
	simulate Simulator,
	networkPassphrase string,
	sourceAccount string,
	sequence int64,
	op *txnbuild.InvokeHostFunction,
) (string, error) {
	unsignedForSim, err := buildInvokeTx(sourceAccount, sequence, op)
	if err != nil {
		return "", fmt.Errorf("stellarx: build tx for simulation: %w", err)
	}
	simXDR, err := unsignedForSim.Base64()
	if err != nil {
		return "", fmt.Errorf("stellarx: encode simulation tx: %w", err)
	}

	sim, err := simulate(ctx, simXDR)
	if err != nil {
		return "", fmt.Errorf("stellarx: simulate: %w", err)
	}

	var sorobanData xdr.SorobanTransactionData
	if err := xdr.SafeUnmarshalBase64(sim.TransactionDataXDR, &sorobanData); err != nil {
		return "", fmt.Errorf("stellarx: decode simulated transaction data: %w", err)
	}
	op.Ext = xdr.TransactionExt{V: 1, SorobanData: &sorobanData}

	// op.Auth is only empty here for calls whose require_auth target is one
	// of the invocation's own arguments (deposit/withdraw/lock/claim) —
	// recording-mode simulation is what produces that entry; nothing else
	// in this backend ever authorizes moving a user's funds. force_collect
	// arrives with op.Auth already set (the sender's pre-signed entry via
	// AttachAuthEntry) and that must never be overwritten here.
	if len(op.Auth) == 0 && len(sim.AuthXDR) > 0 {
		entries := make([]xdr.SorobanAuthorizationEntry, 0, len(sim.AuthXDR))
		for _, b64 := range sim.AuthXDR {
			var entry xdr.SorobanAuthorizationEntry
			if err := xdr.SafeUnmarshalBase64(b64, &entry); err != nil {
				return "", fmt.Errorf("stellarx: decode simulated auth entry: %w", err)
			}
			entries = append(entries, entry)
		}
		op.Auth = entries
	}

	final, err := buildInvokeTx(sourceAccount, sequence, op)
	if err != nil {
		return "", fmt.Errorf("stellarx: build final tx: %w", err)
	}
	return final.Base64()
}

func buildInvokeTx(sourceAccount string, sequence int64, op *txnbuild.InvokeHostFunction) (*txnbuild.Transaction, error) {
	acc := &txnbuild.SimpleAccount{AccountID: sourceAccount, Sequence: sequence}
	return txnbuild.NewTransaction(txnbuild.TransactionParams{
		SourceAccount:        acc,
		IncrementSequenceNum: true,
		Operations:           []txnbuild.Operation{op},
		BaseFee:              txnbuild.MinBaseFee,
		Preconditions:        txnbuild.Preconditions{TimeBounds: txnbuild.NewTimeout(300)},
	})
}
