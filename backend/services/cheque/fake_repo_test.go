package cheque

import (
	"context"
	"errors"
	"math/big"
	"time"
)

// fakeRepo is an in-memory chequeRepo double. It intentionally mirrors only
// the behavior Service actually depends on (transition guards, the active-
// reservation conflict, pool bookkeeping) — it is not a Postgres emulator.
type fakeRepo struct {
	cheques map[string]Cheque
	pools   map[string]PoolDeposit
	active  map[string]bool // sender -> has an active reservation

	// auditLog records every InsertAudit call for tests that want to
	// assert an audit trail was written.
	auditLog []auditEntry

	// failOn lets a test force a specific method call to fail, keyed by
	// method name, to drive DB-error paths without a real database.
	failOn map[string]error
}

type auditEntry struct {
	actor, action string
	details       any
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{
		cheques: map[string]Cheque{},
		pools:   map[string]PoolDeposit{},
		active:  map[string]bool{},
		failOn:  map[string]error{},
	}
}

func (f *fakeRepo) InsertAudit(ctx context.Context, actor, action string, details any) error {
	if err := f.err("InsertAudit"); err != nil {
		return err
	}
	f.auditLog = append(f.auditLog, auditEntry{actor: actor, action: action, details: details})
	return nil
}

func (f *fakeRepo) err(method string) error { return f.failOn[method] }

func (f *fakeRepo) CreateReservedCheque(ctx context.Context, c Cheque) error {
	if err := f.err("CreateReservedCheque"); err != nil {
		return err
	}
	if f.active[c.SenderAddress] {
		return ErrAlreadyActiveInRepo
	}
	f.active[c.SenderAddress] = true
	c.CreatedAt = time.Now()
	c.UpdatedAt = time.Now()
	f.cheques[c.ID] = c
	return nil
}

func (f *fakeRepo) GetCheque(ctx context.Context, id string) (Cheque, error) {
	if err := f.err("GetCheque"); err != nil {
		return Cheque{}, err
	}
	c, ok := f.cheques[id]
	if !ok {
		return Cheque{}, ErrNotFoundInRepo
	}
	return c, nil
}

func (f *fakeRepo) SetPreauthEntry(ctx context.Context, id, entryXDR string) error {
	if err := f.err("SetPreauthEntry"); err != nil {
		return err
	}
	c, ok := f.cheques[id]
	if !ok {
		return ErrNotFoundInRepo
	}
	c.PreauthEntryXDR = entryXDR
	f.cheques[id] = c
	return nil
}

func (f *fakeRepo) SetLockTxHash(ctx context.Context, id, txHash string) error {
	if err := f.err("SetLockTxHash"); err != nil {
		return err
	}
	c, ok := f.cheques[id]
	if !ok {
		return ErrNotFoundInRepo
	}
	c.LockTxHash = txHash
	f.cheques[id] = c
	return nil
}

func (f *fakeRepo) Transition(ctx context.Context, id string, from, to State, cause, txHash string) error {
	if err := f.err("Transition"); err != nil {
		return err
	}
	c, ok := f.cheques[id]
	if !ok {
		return ErrNotFoundInRepo
	}
	if c.State != from {
		return ErrBadTransitionInRepo
	}
	c.State = to
	if txHash != "" {
		c.LockTxHash = txHash
	}
	c.UpdatedAt = time.Now()
	f.cheques[id] = c
	if to.IsTerminal() {
		delete(f.active, c.SenderAddress)
	}
	return nil
}

func (f *fakeRepo) ListActiveForAddress(ctx context.Context, address string) ([]Cheque, error) {
	if err := f.err("ListActiveForAddress"); err != nil {
		return nil, err
	}
	var out []Cheque
	for _, c := range f.cheques {
		if c.State.IsTerminal() {
			continue
		}
		if c.SenderAddress == address || c.ReceiverAddress == address {
			out = append(out, c)
		}
	}
	return out, nil
}

func (f *fakeRepo) ExpiredFundedCheques(ctx context.Context, asOf time.Time) ([]Cheque, error) {
	if err := f.err("ExpiredFundedCheques"); err != nil {
		return nil, err
	}
	var out []Cheque
	for _, c := range f.cheques {
		if c.State == StateHavuzda && !c.ExpiresAt.After(asOf) {
			out = append(out, c)
		}
	}
	return out, nil
}

func (f *fakeRepo) GetPool(ctx context.Context, owner string) (PoolDeposit, bool, error) {
	if err := f.err("GetPool"); err != nil {
		return PoolDeposit{}, false, err
	}
	p, ok := f.pools[owner]
	if !ok {
		return PoolDeposit{OwnerAddress: owner, AmountRaw: "0"}, false, nil
	}
	return p, true, nil
}

func (f *fakeRepo) RecordDeposit(ctx context.Context, owner, amountRaw string, decimals uint8, ledgerSeq int64) error {
	if err := f.err("RecordDeposit"); err != nil {
		return err
	}
	p := f.pools[owner]
	p.OwnerAddress = owner
	p.Decimals = decimals
	p.LastDepositLedger = ledgerSeq
	p.LastDepositAt = time.Now()
	if p.AmountRaw == "" {
		p.AmountRaw = "0"
	}
	p.AmountRaw = addDecimalStrings(p.AmountRaw, amountRaw)
	f.pools[owner] = p
	return nil
}

func (f *fakeRepo) RecordWithdraw(ctx context.Context, owner, amountRaw string) error {
	if err := f.err("RecordWithdraw"); err != nil {
		return err
	}
	p, ok := f.pools[owner]
	if !ok {
		return errors.New("fakeRepo: no pool row for owner")
	}
	p.AmountRaw = subDecimalStrings(p.AmountRaw, amountRaw)
	f.pools[owner] = p
	return nil
}

// addDecimalStrings/subDecimalStrings do plain base-10 bigint arithmetic on
// the raw strings the way Postgres's `amount_raw + EXCLUDED.amount_raw`
// column update would — enough fidelity for test assertions.
func addDecimalStrings(a, b string) string {
	x, _ := new(big.Int).SetString(a, 10)
	y, _ := new(big.Int).SetString(b, 10)
	if x == nil {
		x = big.NewInt(0)
	}
	if y == nil {
		y = big.NewInt(0)
	}
	return new(big.Int).Add(x, y).String()
}

func subDecimalStrings(a, b string) string {
	x, _ := new(big.Int).SetString(a, 10)
	y, _ := new(big.Int).SetString(b, 10)
	if x == nil {
		x = big.NewInt(0)
	}
	if y == nil {
		y = big.NewInt(0)
	}
	return new(big.Int).Sub(x, y).String()
}
