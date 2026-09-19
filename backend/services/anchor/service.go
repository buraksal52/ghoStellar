package anchor

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/stellar/go-stellar-sdk/txnbuild"

	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/ports"
)

var ErrDBNotReadyErr = errors.New(ErrDBNotReady)

// Config is deliberately single-anchor for the MVP (Açık Varsayım #1): one
// operator-configured domain, never a user-supplied one (architecture.md
// §10). The {id} in every route is kept for forward compatibility with a
// real allow-list once more than one anchor is onboarded.
type Config struct {
	AnchorID          string
	AnchorDomain      string
	AssetCode         string
	AssetIssuer       string
	Decimals          uint8
	NetworkPassphrase string
}

type Service struct {
	cfg    Config
	pool   *dbx.Pool
	client *Client
	chain  ports.ChainGateway

	cachedInfo *Info
}

func NewService(cfg Config, pool *dbx.Pool, client *Client, chain ports.ChainGateway) *Service {
	return &Service{cfg: cfg, pool: pool, client: client, chain: chain}
}

func (s *Service) repo() (*Repository, error) {
	p := s.pool.Get()
	if p == nil {
		return nil, ErrDBNotReadyErr
	}
	return NewRepository(p), nil
}

func (s *Service) checkID(id string) error {
	if id != s.cfg.AnchorID {
		return errNotAllowed
	}
	return nil
}

// Info resolves (and in-process caches) the configured anchor's SEP-1
// stellar.toml. A real implementation would TTL this cache; the MVP
// re-resolves once per process lifetime, which is enough for a demo/single
// anchor and avoids a cache-invalidation feature nobody asked for yet.
func (s *Service) Info(ctx context.Context, id string) (Info, error) {
	if err := s.checkID(id); err != nil {
		return Info{}, err
	}
	if s.cachedInfo != nil {
		return *s.cachedInfo, nil
	}
	toml, err := s.client.FetchTOML(s.cfg.AnchorDomain)
	if err != nil {
		return Info{}, err
	}
	quoteServer, err := s.client.FetchQuoteServer(s.cfg.AnchorDomain)
	if err != nil {
		return Info{}, err
	}
	info := Info{
		ID:               s.cfg.AnchorID,
		Domain:           s.cfg.AnchorDomain,
		SigningKey:       toml.SigningKey,
		WebAuthEndpoint:  toml.WebAuthEndpoint,
		TransferServer:   toml.TransferServer,
		KYCServer:        toml.KycServer,
		QuoteServer:      quoteServer,
		TransferServer24: toml.TransferServer0024,
		AssetCode:        s.cfg.AssetCode,
		AssetIssuer:      s.cfg.AssetIssuer,
	}
	s.cachedInfo = &info
	return info, nil
}

// ProxySep6, ProxySep12, and ProxySep38 forward standards-defined API calls
// to the one operator-configured anchor. The anchor JWT is forwarded only
// for the duration of the request and is never persisted.
func (s *Service) ProxySep6(ctx context.Context, id, method, path, rawQuery, token string, body []byte) (json.RawMessage, error) {
	info, err := s.Info(ctx, id)
	if err != nil {
		return nil, err
	}
	if info.TransferServer == "" {
		return nil, fmt.Errorf("%s: anchor does not publish TRANSFER_SERVER", ErrUpstreamFailed)
	}
	return s.client.ProxyJSON(ctx, method, info.TransferServer, path, rawQuery, token, body)
}

func (s *Service) ProxySep12(ctx context.Context, id, method, path, rawQuery, token string, body []byte) (json.RawMessage, error) {
	info, err := s.Info(ctx, id)
	if err != nil {
		return nil, err
	}
	if info.KYCServer == "" {
		return nil, fmt.Errorf("%s: anchor does not publish KYC_SERVER", ErrUpstreamFailed)
	}
	return s.client.ProxyJSON(ctx, method, info.KYCServer, path, rawQuery, token, body)
}

func (s *Service) ProxySep38(ctx context.Context, id, method, path, rawQuery, token string, body []byte) (json.RawMessage, error) {
	info, err := s.Info(ctx, id)
	if err != nil {
		return nil, err
	}
	if info.QuoteServer == "" {
		return nil, fmt.Errorf("%s: anchor does not publish ANCHOR_QUOTE_SERVER", ErrUpstreamFailed)
	}
	return s.client.ProxyJSON(ctx, method, info.QuoteServer, path, rawQuery, token, body)
}

func (s *Service) Challenge(ctx context.Context, id, account string) (string, error) {
	info, err := s.Info(ctx, id)
	if err != nil {
		return "", err
	}
	if info.WebAuthEndpoint == "" {
		return "", fmt.Errorf("%s: anchor does not publish WEB_AUTH_ENDPOINT", ErrUpstreamFailed)
	}
	return s.client.SEP10Challenge(ctx, info.WebAuthEndpoint, account)
}

func (s *Service) Token(ctx context.Context, id, signedTransaction string) (string, error) {
	info, err := s.Info(ctx, id)
	if err != nil {
		return "", err
	}
	return s.client.SEP10Token(ctx, info.WebAuthEndpoint, signedTransaction)
}

// StartDeposit begins a SEP-24 deposit and records the pending transaction.
func (s *Service) StartDeposit(ctx context.Context, id, anchorToken, stellarAddress string) (txID, interactiveURL string, err error) {
	return s.startInteractive(ctx, id, "deposit", anchorToken, stellarAddress)
}

func (s *Service) StartWithdraw(ctx context.Context, id, anchorToken, stellarAddress string) (txID, interactiveURL string, err error) {
	return s.startInteractive(ctx, id, "withdraw", anchorToken, stellarAddress)
}

func (s *Service) startInteractive(ctx context.Context, id, kind, anchorToken, stellarAddress string) (string, string, error) {
	if anchorToken == "" {
		return "", "", errAuthRequired
	}
	info, err := s.Info(ctx, id)
	if err != nil {
		return "", "", err
	}
	txID, interactiveURL, err := s.client.SEP24Interactive(ctx, info.TransferServer24, kind, anchorToken, info.AssetCode, stellarAddress)
	if err != nil {
		return "", "", err
	}
	repo, err := s.repo()
	if err != nil {
		return "", "", err
	}
	if err := repo.UpsertTransaction(ctx, Transaction{
		ID: txID, AnchorID: id, StellarAddress: stellarAddress, Kind: kind, State: "incomplete",
	}); err != nil {
		return "", "", fmt.Errorf("anchor: record transaction: %w", err)
	}
	return txID, interactiveURL, nil
}

// ReportTransaction is how this MVP learns a SEP-24 transaction's status:
// self-reported by the client, which is the only party holding the
// anchor's JWT (custody decision, docs/reference/platform/
// anchor-entegrasyonu.md). pay-scheduler-service does not — and cannot —
// poll the anchor on the user's behalf.
func (s *Service) ReportTransaction(ctx context.Context, id, stellarAddress string, t Transaction) error {
	if err := s.checkID(id); err != nil {
		return err
	}
	repo, err := s.repo()
	if err != nil {
		return err
	}
	t.AnchorID = id
	t.StellarAddress = stellarAddress
	return repo.UpdateTransaction(ctx, t)
}

func (s *Service) RecordSep6Transaction(ctx context.Context, id, stellarAddress string, t Transaction) error {
	if err := s.checkID(id); err != nil {
		return err
	}
	repo, err := s.repo()
	if err != nil {
		return err
	}
	t.AnchorID, t.StellarAddress = id, stellarAddress
	return repo.CreateTransaction(ctx, t)
}

func (s *Service) ListTransactions(ctx context.Context, stellarAddress string) ([]Transaction, error) {
	repo, err := s.repo()
	if err != nil {
		return nil, err
	}
	return repo.ListForAddress(ctx, stellarAddress)
}

// TrustlineXDR builds the unsigned change_trust operation for the
// configured asset — the mandatory onboarding step before any deposit
// (p2p doc A4/F3; docs/reference/platform/anchor-entegrasyonu.md
// "Trustline").
func (s *Service) TrustlineXDR(ctx context.Context, owner string) (string, error) {
	if s.cfg.AssetIssuer == "" {
		return "", fmt.Errorf("%s: anchor asset issuer not configured", ErrUpstreamFailed)
	}
	account, err := s.chain.GetAccount(ctx, owner)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errChainUnavailable, err)
	}
	asset := txnbuild.CreditAsset{Code: s.cfg.AssetCode, Issuer: s.cfg.AssetIssuer}
	op := &txnbuild.ChangeTrust{
		Line:          asset.MustToChangeTrustAsset(),
		SourceAccount: owner,
	}
	tx, err := txnbuild.NewTransaction(txnbuild.TransactionParams{
		SourceAccount:        &txnbuild.SimpleAccount{AccountID: owner, Sequence: account.Sequence},
		IncrementSequenceNum: true,
		Operations:           []txnbuild.Operation{op},
		BaseFee:              txnbuild.MinBaseFee,
		Preconditions:        txnbuild.Preconditions{TimeBounds: txnbuild.NewTimeout(300)},
	})
	if err != nil {
		return "", fmt.Errorf("anchor: build trustline tx: %w", err)
	}
	return tx.Base64()
}

// ConfirmTrustline records that a change_trust op has been submitted
// successfully — called by the client after pay-tx-service confirms it.
func (s *Service) ConfirmTrustline(ctx context.Context, owner string, ledgerSeq int64) error {
	repo, err := s.repo()
	if err != nil {
		return err
	}
	return repo.SetTrustline(ctx, owner, s.cfg.AssetCode, s.cfg.AssetIssuer, "active", ledgerSeq)
}

var (
	errNotAllowed       = errors.New(ErrNotAllowed)
	errAuthRequired     = errors.New(ErrAuthRequired)
	errChainUnavailable = errors.New(ErrChainUnavailable)
)
