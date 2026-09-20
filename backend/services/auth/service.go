// Package auth implements pay-auth-service: SEP-10 challenge issuance and
// verification, RS256 JWT minting, and the minimal user profile that
// identity resolves to. See docs/reference/platform/architecture.md §5.1
// and §10.
package auth

import (
	"context"
	"crypto/rsa"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/stellar/go-stellar-sdk/keypair"
	"github.com/stellar/go-stellar-sdk/txnbuild"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/ports"
)

// ErrDBNotReady is returned during the brief post-boot window before the
// database pool finishes its async connect (pkg/dbx) — the HTTP layer
// (dbx.RequireReady) normally intercepts requests before they get this far,
// but Service checks too so it is never nil-pointer-unsafe on its own.
var ErrDBNotReady = errors.New("auth.db_not_ready")

const (
	challengeTimebound = 5 * time.Minute
	accessTokenTTL     = 15 * time.Minute
	refreshTokenTTL    = 30 * 24 * time.Hour

	// fundTimeout bounds the best-effort friendbot call below so a slow or
	// hanging Horizon never turns a successful login into a slow one — and
	// so it outlives a client that disconnects right after POSTing (see
	// fundIfNeeded's use of context.WithoutCancel).
	fundTimeout = 20 * time.Second
)

// Config configures Service. ServerSigningSeed is the "S..." secret of the
// SEP-10 server signing key — the ONLY private key this service holds
// besides the JWT signing key; it never signs on a user's behalf, only its
// own challenge transactions (architecture.md §5.1).
type Config struct {
	ServerSigningSeed string
	HomeDomain        string
	WebAuthDomain     string
	NetworkPassphrase string
	JWTPrivateKey     *rsa.PrivateKey
	JWTPublicKey      *rsa.PublicKey

	// FundNewAccounts turns on the best-effort testnet friendbot fund on
	// first login (SERVICE.md #24). It has no business being true against
	// a mainnet Horizon — cmd/authsvc and cmd/monolith default it off
	// unless NETWORK_PASSPHRASE is the testnet passphrase.
	FundNewAccounts bool
}

type Service struct {
	cfg   Config
	repos func() (authRepo, error)
	chain ports.ChainGateway
	log   *slog.Logger
}

// NewService constructs a Service. pool need not be connected yet — every
// DB-touching method re-derives a Repository from pool.Get() on each call
// and returns ErrDBNotReady during the brief async-connect window at boot
// (pkg/dbx), rather than requiring a two-phase "attach the repo later"
// wiring dance. chain may be nil when cfg.FundNewAccounts is false (e.g. a
// mainnet deploy that never wires a ChainGateway into pay-auth-service at
// all); log defaults to slog.Default() when nil.
func NewService(cfg Config, pool *dbx.Pool, chain ports.ChainGateway, log *slog.Logger) *Service {
	if log == nil {
		log = slog.Default()
	}
	return &Service{cfg: cfg, chain: chain, log: log, repos: func() (authRepo, error) {
		p := pool.Get()
		if p == nil {
			return nil, ErrDBNotReady
		}
		return NewRepository(p), nil
	}}
}

// newServiceWithRepo is the test seam: the same Service, wired to a
// caller-supplied repo instead of a *dbx.Pool.
func newServiceWithRepo(cfg Config, repo authRepo, chain ports.ChainGateway, log *slog.Logger) *Service {
	if log == nil {
		log = slog.Default()
	}
	return &Service{cfg: cfg, chain: chain, log: log, repos: func() (authRepo, error) { return repo, nil }}
}

// Challenge builds a SEP-10 challenge transaction for account to sign.
// account must already be a syntactically valid "G..." address — the
// handler validates that before calling in.
func (s *Service) Challenge(account string) (string, error) {
	tx, err := txnbuild.BuildChallengeTx(
		s.cfg.ServerSigningSeed,
		account,
		s.cfg.WebAuthDomain,
		s.cfg.HomeDomain,
		s.cfg.NetworkPassphrase,
		challengeTimebound,
		nil,
	)
	if err != nil {
		return "", fmt.Errorf("auth: build challenge: %w", err)
	}
	return tx.Base64()
}

// VerifyAndMint validates a client-signed challenge transaction and, on
// success, upserts the user and mints a fresh access/refresh pair.
func (s *Service) VerifyAndMint(ctx context.Context, signedChallengeXDR string) (TokenPair, User, error) {
	serverKP, err := keypair.ParseFull(s.cfg.ServerSigningSeed)
	if err != nil {
		return TokenPair{}, User{}, fmt.Errorf("auth: server keypair: %w", err)
	}

	_, clientAccountID, _, _, err := txnbuild.ReadChallengeTx(
		signedChallengeXDR,
		serverKP.Address(),
		s.cfg.NetworkPassphrase,
		s.cfg.WebAuthDomain,
		[]string{s.cfg.HomeDomain},
	)
	if err != nil {
		return TokenPair{}, User{}, fmt.Errorf("%w: %v", errInvalidChallenge, err)
	}

	// Threshold 1 / weight 1: for the MVP a cheque wallet is a single
	// keypair, not a multisig account — the client account's own signature
	// at its default weight is sufficient (Faz 2 could raise this once
	// multisig/2FA wallets are supported).
	if _, err := txnbuild.VerifyChallengeTxSigners(
		signedChallengeXDR,
		serverKP.Address(),
		s.cfg.NetworkPassphrase,
		s.cfg.WebAuthDomain,
		[]string{s.cfg.HomeDomain},
		clientAccountID,
	); err != nil {
		return TokenPair{}, User{}, fmt.Errorf("%w: %v", errInvalidSignature, err)
	}

	repo, err := s.repos()
	if err != nil {
		return TokenPair{}, User{}, err
	}
	user, err := repo.UpsertUser(ctx, clientAccountID)
	if err != nil {
		return TokenPair{}, User{}, fmt.Errorf("auth: upsert user: %w", err)
	}

	// Best-effort, never fails the login (SERVICE.md #24 mirrors #11's
	// audit-write contract): a testnet wallet that has never held XLM
	// otherwise has no way to pay its own first transaction fee.
	s.fundIfNeeded(ctx, repo, clientAccountID)

	pair, err := s.mintPair(clientAccountID)
	if err != nil {
		return TokenPair{}, User{}, err
	}
	// Best-effort (SERVICE.md #11): an audit write failure must never turn
	// a successful login into a reported failure.
	_ = repo.InsertAudit(ctx, clientAccountID, "auth.login_succeeded", nil)
	return pair, user, nil
}

// fundIfNeeded best-effort funds address via testnet friendbot
// (ports.ChainGateway.Fund) the first time it is seen on chain. It never
// returns an error to its caller — VerifyAndMint's login must succeed
// whether or not friendbot cooperates (SERVICE.md #24). The trigger is "does
// the account exist on chain", not "is this a new DB row": that makes a
// previously-failed fund self-heal on the user's next login, and skips the
// friendbot round trip entirely once an account is funded.
func (s *Service) fundIfNeeded(parent context.Context, repo authRepo, address string) {
	if !s.cfg.FundNewAccounts || s.chain == nil {
		return
	}
	// context.WithoutCancel: a client that disconnects the instant it POSTs
	// must not abort the fund attempt mid-flight — it isn't on the response
	// path at all.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(parent), fundTimeout)
	defer cancel()

	info, err := s.chain.GetAccount(ctx, address)
	if err != nil {
		s.log.Warn("auth: fundIfNeeded: GetAccount failed", "address", address, "error", err)
		return
	}
	if info.Exists {
		return
	}
	if err := s.chain.Fund(ctx, address); err != nil {
		s.log.Warn("auth: fundIfNeeded: friendbot fund failed", "address", address, "error", err)
		return
	}
	_ = repo.InsertAudit(ctx, address, "auth.account_funded", nil)
}

// FundOwnAccount is the manual, on-demand counterpart to fundIfNeeded
// (SERVICE.md #24): backs a "Fund with testnet XLM" button for someone
// already stuck with an unfunded wallet, or who missed the automatic fund
// at login. Unlike fundIfNeeded it does not check whether the account
// already exists first — this is an explicit action a person asked for, and
// a few extra free testnet XLM never hurts.
//
// Always returns (false, nil) rather than an error when funding isn't
// possible (not a testnet deployment, or the friendbot call itself failed)
// — best-effort by design, never something the caller should retry with
// backoff over; the caller just tells the user it didn't work this time.
func (s *Service) FundOwnAccount(ctx context.Context, address string) (bool, error) {
	if !s.cfg.FundNewAccounts || s.chain == nil {
		return false, nil
	}
	ctx, cancel := context.WithTimeout(ctx, fundTimeout)
	defer cancel()
	if err := s.chain.Fund(ctx, address); err != nil {
		s.log.Warn("auth: FundOwnAccount: friendbot fund failed", "address", address, "error", err)
		return false, nil
	}
	return true, nil
}

// Refresh mints a new access token from a still-valid refresh token,
// without requiring the user to sign another SEP-10 challenge.
func (s *Service) Refresh(refreshToken string) (TokenPair, error) {
	// "" (no audience check) here: a refresh token's own aud is verified
	// identically to an access token's (both set it in mintPair), but
	// Refresh's only real gate is the Subject=="refresh" check below —
	// requiring a specific audience would need this method to know its
	// caller's expected audience, which it has no reason to.
	claims, err := authx.VerifyJWT(refreshToken, s.cfg.JWTPublicKey, "")
	if err != nil || claims.Subject != "refresh" {
		return TokenPair{}, errInvalidToken
	}
	return s.mintPair(claims.StellarAccount)
}

// mintPair sets Issuer/Audience on both tokens (SERVICE.md #19) —
// jwt.RegisteredClaims already carries these fields, this is the first
// place anything populates them. Audience is WebAuthDomain: SEP-10 JWTs
// conventionally bind to the web-auth domain, and it's the one piece of
// per-deployment identity every other service can also be configured with
// (WEB_AUTH_DOMAIN) to verify against via authx.RequireBearer.
func (s *Service) mintPair(stellarAccount string) (TokenPair, error) {
	now := time.Now()
	access := authx.Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(now.Add(accessTokenTTL)),
			IssuedAt:  jwt.NewNumericDate(now),
			Subject:   "access", // authx.VerifyAccessToken requires this — a refresh token must never work as a bearer token
			Issuer:    "pay-auth-service",
			Audience:  jwt.ClaimStrings{s.cfg.WebAuthDomain},
		},
		StellarAccount: stellarAccount,
	}
	refresh := authx.Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(now.Add(refreshTokenTTL)),
			IssuedAt:  jwt.NewNumericDate(now),
			Subject:   "refresh",
			Issuer:    "pay-auth-service",
			Audience:  jwt.ClaimStrings{s.cfg.WebAuthDomain},
		},
		StellarAccount: stellarAccount,
	}

	accessTok, err := jwt.NewWithClaims(jwt.SigningMethodRS256, access).SignedString(s.cfg.JWTPrivateKey)
	if err != nil {
		return TokenPair{}, fmt.Errorf("auth: sign access token: %w", err)
	}
	refreshTok, err := jwt.NewWithClaims(jwt.SigningMethodRS256, refresh).SignedString(s.cfg.JWTPrivateKey)
	if err != nil {
		return TokenPair{}, fmt.Errorf("auth: sign refresh token: %w", err)
	}
	return TokenPair{AccessToken: accessTok, RefreshToken: refreshTok, ExpiresIn: int64(accessTokenTTL.Seconds())}, nil
}

func (s *Service) GetProfile(ctx context.Context, address string) (User, error) {
	repo, err := s.repos()
	if err != nil {
		return User{}, err
	}
	return repo.GetUserByAddress(ctx, address)
}

var (
	errInvalidChallenge = errors.New(ErrInvalidChallenge)
	errInvalidSignature = errors.New(ErrInvalidSignature)
	errInvalidToken     = errors.New(ErrInvalidToken)
)
