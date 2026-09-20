package anchor

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"strconv"
	"sync"

	"github.com/stellar/go-stellar-sdk/txnbuild"

	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/pkg/money"
	"github.com/local-payment/backend/pkg/stellarx"
	"github.com/local-payment/backend/ports"
)

var ErrDBNotReadyErr = errors.New(ErrDBNotReady)

// Config is deliberately single-anchor for the MVP (Açık Varsayım #1): one
// operator-configured domain, never a user-supplied one (architecture.md
// §10). The {id} in every route is kept for forward compatibility with a
// real allow-list once more than one anchor is onboarded.
type Config struct {
	AnchorID     string
	AnchorDomain string
	AssetCode    string
	AssetIssuer  string
	Decimals     uint8
}

type Service struct {
	cfg    Config
	repos  func() (anchorRepo, error)
	client *Client
	chain  ports.ChainGateway
	log    *slog.Logger

	infoMu     sync.Mutex
	cachedInfo *Info
}

func NewService(cfg Config, pool *dbx.Pool, client *Client, chain ports.ChainGateway, log *slog.Logger) *Service {
	return &Service{cfg: cfg, client: client, chain: chain, log: log, repos: func() (anchorRepo, error) {
		p := pool.Get()
		if p == nil {
			return nil, ErrDBNotReadyErr
		}
		return NewRepository(p), nil
	}}
}

// newServiceWithRepo is the test seam: the same Service, wired to a
// caller-supplied repo instead of a *dbx.Pool.
func newServiceWithRepo(cfg Config, repo anchorRepo, client *Client, chain ports.ChainGateway, log *slog.Logger) *Service {
	return &Service{cfg: cfg, client: client, chain: chain, log: log, repos: func() (anchorRepo, error) { return repo, nil }}
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
//
// Guarded by infoMu: Info is called concurrently by every request this
// service handles (challenge, deposit, withdraw, every sep6/12/38 call),
// so both the cache read/write and the allow-list registration below must
// be serialized — a bare pointer field here would be a genuine data race.
func (s *Service) Info(ctx context.Context, id string) (Info, error) {
	if err := s.checkID(id); err != nil {
		return Info{}, err
	}

	s.infoMu.Lock()
	defer s.infoMu.Unlock()

	if s.cachedInfo != nil {
		return *s.cachedInfo, nil
	}
	toml, err := s.client.FetchTOML(s.cfg.AnchorDomain)
	if err != nil {
		return Info{}, err
	}
	// ANCHOR_QUOTE_SERVER has no field on the SDK's stellartoml.Response,
	// so it takes a second fetch of the same toml. That fetch is a
	// best-effort lookup of an OPTIONAL field, not a hard dependency: a
	// transient failure here must never block SEP-10 auth or SEP-6
	// deposit/withdraw, which never needed it (fixes the single-point-of-
	// failure this used to be).
	quoteServer, err := s.client.FetchQuoteServer(s.cfg.AnchorDomain)
	if err != nil {
		s.log.Warn("anchor: could not resolve ANCHOR_QUOTE_SERVER; SEP-38 quotes will be unavailable", "error", err)
		quoteServer = ""
	}

	// Register every host this anchor's OWN toml delegates to. A real
	// anchor commonly hosts its home domain and its SEP-6/10/38 API on
	// different hosts (e.g. a bare domain plus an `api.` subdomain); the
	// SSRF allow-list otherwise only ever contains the bare ANCHOR_DOMAIN
	// used to fetch the toml, which would silently break every anchor
	// call whose endpoint lives elsewhere. Every host added here still
	// comes from the operator-configured anchor's own published
	// configuration, never from a request (architecture.md §10).
	for _, endpoint := range []string{toml.WebAuthEndpoint, toml.TransferServer, toml.KycServer, quoteServer, toml.TransferServer0024} {
		if host := hostnameOf(endpoint); host != "" {
			s.client.AllowHost(host)
		}
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

func hostnameOf(rawURL string) string {
	if rawURL == "" {
		return ""
	}
	u, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	return u.Hostname()
}

// ProxySep6, ProxySep12, and ProxySep38 forward standards-defined API calls
// to the one operator-configured anchor. The anchor JWT is forwarded only
// for the duration of the request and is never persisted.
func (s *Service) ProxySep6(ctx context.Context, id, method, path, rawQuery, token, contentType string, body []byte) (json.RawMessage, error) {
	info, err := s.Info(ctx, id)
	if err != nil {
		return nil, err
	}
	if info.TransferServer == "" {
		return nil, fmt.Errorf("%s: anchor does not publish TRANSFER_SERVER", ErrUpstreamFailed)
	}
	return s.client.ProxyJSON(ctx, method, info.TransferServer, path, rawQuery, token, contentType, body)
}

func (s *Service) ProxySep12(ctx context.Context, id, method, path, rawQuery, token, contentType string, body []byte) (json.RawMessage, error) {
	info, err := s.Info(ctx, id)
	if err != nil {
		return nil, err
	}
	if info.KYCServer == "" {
		return nil, fmt.Errorf("%s: anchor does not publish KYC_SERVER", ErrUpstreamFailed)
	}
	return s.client.ProxyJSON(ctx, method, info.KYCServer, path, rawQuery, token, contentType, body)
}

func (s *Service) ProxySep38(ctx context.Context, id, method, path, rawQuery, token, contentType string, body []byte) (json.RawMessage, error) {
	info, err := s.Info(ctx, id)
	if err != nil {
		return nil, err
	}
	if info.QuoteServer == "" {
		return nil, fmt.Errorf("%s: anchor does not publish ANCHOR_QUOTE_SERVER", ErrUpstreamFailed)
	}
	return s.client.ProxyJSON(ctx, method, info.QuoteServer, path, rawQuery, token, contentType, body)
}

func (s *Service) Challenge(ctx context.Context, id, account string) (transaction, networkPassphrase string, err error) {
	info, err := s.Info(ctx, id)
	if err != nil {
		return "", "", err
	}
	if info.WebAuthEndpoint == "" {
		return "", "", fmt.Errorf("%s: anchor does not publish WEB_AUTH_ENDPOINT", ErrUpstreamFailed)
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
	repo, err := s.repos()
	if err != nil {
		return "", "", err
	}
	// Fast, friendly pre-check using this service's OWN pay.trustlines
	// cache (SERVICE.md #11 — previously write-only, never read anywhere):
	// a client without a recorded active trustline would otherwise only
	// find out after round-tripping to the anchor's own SEP-24 endpoint.
	// Best-effort: a repo error here falls through to the anchor call
	// rather than blocking the user on a diagnostic-only check.
	if state, found, tErr := repo.GetTrustlineState(ctx, stellarAddress, s.cfg.AssetCode, s.cfg.AssetIssuer); tErr == nil {
		if !found || state != "active" {
			return "", "", errTrustlineMissing
		}
	}

	info, err := s.Info(ctx, id)
	if err != nil {
		return "", "", err
	}
	// An anchor that publishes no SEP-24 server (the TR mock anchor is
	// SEP-6 only) would otherwise fail deep inside requireHTTPS on the
	// schemeless "/transactions/..." URL; fail here with a readable reason.
	if info.TransferServer24 == "" {
		return "", "", fmt.Errorf("%s: anchor publishes no SEP-24 transfer server; use the SEP-6 endpoints", ErrUpstreamFailed)
	}
	txID, interactiveURL, err := s.client.SEP24Interactive(ctx, info.TransferServer24, kind, anchorToken, info.AssetCode, stellarAddress)
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
	repo, err := s.repos()
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
	repo, err := s.repos()
	if err != nil {
		return err
	}
	t.AnchorID, t.StellarAddress = id, stellarAddress
	return repo.CreateTransaction(ctx, t)
}

func (s *Service) ListTransactions(ctx context.Context, stellarAddress string) ([]Transaction, error) {
	repo, err := s.repos()
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
	if !account.Exists {
		// A brand-new wallet has no on-chain account until it's funded (D6:
		// Horizon is authoritative, we don't guess). Building a tx with
		// Sequence 0 against a nonexistent source would sign and submit a
		// transaction Horizon can only reject — fail fast with a message
		// the client actually recognizes instead.
		return "", errAccountNotFunded
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

// WithdrawPaymentXDR builds the unsigned payment a SEP-6 withdraw needs: the
// user sends the anchor's asset to the anchor's account with the memo the
// anchor returned from GET /withdraw. Like TrustlineXDR the backend never
// signs — the device signs and pay-tx-service submits.
func (s *Service) WithdrawPaymentXDR(ctx context.Context, owner, destination, memoType, memo, amountStr string) (string, error) {
	if s.cfg.AssetIssuer == "" {
		return "", fmt.Errorf("%s: anchor asset issuer not configured", ErrUpstreamFailed)
	}
	if !stellarx.IsValidAccountAddress(destination) {
		return "", fmt.Errorf("%w: destination is not a valid Stellar account", errBadRequest)
	}
	amount, err := money.ParseAmount(amountStr, money.AssetID{Code: s.cfg.AssetCode, Issuer: s.cfg.AssetIssuer}, s.cfg.Decimals)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errBadRequest, err)
	}
	if amount.Raw.Sign() <= 0 {
		return "", fmt.Errorf("%w: amount must be positive", errBadRequest)
	}
	txMemo, err := withdrawMemo(memoType, memo)
	if err != nil {
		return "", err
	}
	account, err := s.chain.GetAccount(ctx, owner)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errChainUnavailable, err)
	}
	if !account.Exists {
		return "", errAccountNotFunded
	}
	op := &txnbuild.Payment{
		Destination:   destination,
		Amount:        amount.String(),
		Asset:         txnbuild.CreditAsset{Code: s.cfg.AssetCode, Issuer: s.cfg.AssetIssuer},
		SourceAccount: owner,
	}
	tx, err := txnbuild.NewTransaction(txnbuild.TransactionParams{
		SourceAccount:        &txnbuild.SimpleAccount{AccountID: owner, Sequence: account.Sequence},
		IncrementSequenceNum: true,
		Operations:           []txnbuild.Operation{op},
		Memo:                 txMemo,
		BaseFee:              txnbuild.MinBaseFee,
		Preconditions:        txnbuild.Preconditions{TimeBounds: txnbuild.NewTimeout(300)},
	})
	if err != nil {
		return "", fmt.Errorf("anchor: build withdraw payment tx: %w", err)
	}
	return tx.Base64()
}

// withdrawMemo maps the SEP-6 memo_type/memo pair to a transaction memo. An
// anchor that returns no memo at all is valid (the account alone identifies
// the user), so an empty memo yields no memo.
func withdrawMemo(memoType, memo string) (txnbuild.Memo, error) {
	if memo == "" {
		return nil, nil
	}
	switch memoType {
	case "id":
		id, err := strconv.ParseUint(memo, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("%w: memo_type id needs an unsigned integer memo", errBadRequest)
		}
		return txnbuild.MemoID(id), nil
	case "text":
		if len(memo) > 28 {
			return nil, fmt.Errorf("%w: text memo exceeds 28 bytes", errBadRequest)
		}
		return txnbuild.MemoText(memo), nil
	default:
		return nil, fmt.Errorf("%w: unsupported memo_type %q", errBadRequest, memoType)
	}
}

// ConfirmTrustline refreshes the pay.trustlines cache from the chain, which
// stays the source of truth: the client only says "I submitted it", so the
// row is marked active only if the trustline is really there, and the ledger
// recorded is the chain's own — never a client-supplied value. A trustline
// that is not on-chain is recorded as "missing" (which also repairs a row
// wrongly left "active" by an earlier unverified confirm) and reported as
// errTrustlineMissing.
func (s *Service) ConfirmTrustline(ctx context.Context, owner string) error {
	repo, err := s.repos()
	if err != nil {
		return err
	}
	trustline, err := s.chain.GetTrustline(ctx, owner, s.cfg.AssetCode, s.cfg.AssetIssuer)
	if err != nil {
		return fmt.Errorf("%w: %v", errChainUnavailable, err)
	}
	if !trustline.Exists {
		if err := repo.SetTrustline(ctx, owner, s.cfg.AssetCode, s.cfg.AssetIssuer, "missing", 0); err != nil {
			return err
		}
		return errTrustlineMissing
	}
	ledger, err := s.chain.GetLedger(ctx)
	if err != nil {
		return fmt.Errorf("%w: %v", errChainUnavailable, err)
	}
	return repo.SetTrustline(ctx, owner, s.cfg.AssetCode, s.cfg.AssetIssuer, "active", ledger.Sequence)
}

var (
	errNotAllowed       = errors.New(ErrNotAllowed)
	errAuthRequired     = errors.New(ErrAuthRequired)
	errChainUnavailable = errors.New(ErrChainUnavailable)
	errTrustlineMissing = errors.New(ErrTrustlineMissing)
	errBadRequest       = errors.New(ErrBadRequest)
	errAccountNotFunded = errors.New(ErrAccountNotFunded)
)
