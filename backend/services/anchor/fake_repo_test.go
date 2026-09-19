package anchor

import (
	"context"
)

// fakeRepo is an in-memory anchorRepo double.
type fakeRepo struct {
	transactions map[string]Transaction // key: anchorID+"/"+txID
	trustlines   map[string]string      // key: address+"/"+code+"/"+issuer -> state
	auditLog     []auditEntry
	failOn       map[string]error
}

type auditEntry struct {
	actor, action string
	details       any
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{
		transactions: map[string]Transaction{},
		trustlines:   map[string]string{},
		failOn:       map[string]error{},
	}
}

func txKey(anchorID, id string) string { return anchorID + "/" + id }

func (f *fakeRepo) UpsertTransaction(ctx context.Context, t Transaction) error {
	if err := f.failOn["UpsertTransaction"]; err != nil {
		return err
	}
	f.transactions[txKey(t.AnchorID, t.ID)] = t
	return nil
}

func (f *fakeRepo) CreateTransaction(ctx context.Context, t Transaction) error {
	if err := f.failOn["CreateTransaction"]; err != nil {
		return err
	}
	f.transactions[txKey(t.AnchorID, t.ID)] = t
	return nil
}

func (f *fakeRepo) UpdateTransaction(ctx context.Context, t Transaction) error {
	if err := f.failOn["UpdateTransaction"]; err != nil {
		return err
	}
	key := txKey(t.AnchorID, t.ID)
	existing, ok := f.transactions[key]
	if !ok {
		return ErrNotFoundInRepo
	}
	if existing.StellarAddress != t.StellarAddress {
		return ErrNotFoundInRepo
	}
	existing.State = t.State
	if t.AmountRaw != "" {
		existing.AmountRaw = t.AmountRaw
	}
	if t.StellarTxHash != "" {
		existing.StellarTxHash = t.StellarTxHash
	}
	f.transactions[key] = existing
	return nil
}

func (f *fakeRepo) ListForAddress(ctx context.Context, address string) ([]Transaction, error) {
	if err := f.failOn["ListForAddress"]; err != nil {
		return nil, err
	}
	var out []Transaction
	for _, t := range f.transactions {
		if t.StellarAddress == address {
			out = append(out, t)
		}
	}
	return out, nil
}

func (f *fakeRepo) SetTrustline(ctx context.Context, address, assetCode, assetIssuer, state string, ledgerSeq int64) error {
	if err := f.failOn["SetTrustline"]; err != nil {
		return err
	}
	f.trustlines[address+"/"+assetCode+"/"+assetIssuer] = state
	return nil
}

func (f *fakeRepo) GetTrustlineState(ctx context.Context, address, assetCode, assetIssuer string) (string, bool, error) {
	if err := f.failOn["GetTrustlineState"]; err != nil {
		return "", false, err
	}
	state, ok := f.trustlines[address+"/"+assetCode+"/"+assetIssuer]
	return state, ok, nil
}

func (f *fakeRepo) InsertAudit(ctx context.Context, actor, action string, details any) error {
	if err := f.failOn["InsertAudit"]; err != nil {
		return err
	}
	f.auditLog = append(f.auditLog, auditEntry{actor: actor, action: action, details: details})
	return nil
}
