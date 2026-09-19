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
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/stellar/go-stellar-sdk/keypair"
	"github.com/stellar/go-stellar-sdk/txnbuild"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/dbx"
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
}

type Service struct {
	cfg   Config
	repos func() (authRepo, error)
}

// NewService constructs a Service. pool need not be connected yet — every
// DB-touching method re-derives a Repository from pool.Get() on each call
// and returns ErrDBNotReady during the brief async-connect window at boot
// (pkg/dbx), rather than requiring a two-phase "attach the repo later"
// wiring dance.
func NewService(cfg Config, pool *dbx.Pool) *Service {
	return &Service{cfg: cfg, repos: func() (authRepo, error) {
		p := pool.Get()
		if p == nil {
			return nil, ErrDBNotReady
		}
		return NewRepository(p), nil
	}}
}

// newServiceWithRepo is the test seam: the same Service, wired to a
// caller-supplied repo instead of a *dbx.Pool.
func newServiceWithRepo(cfg Config, repo authRepo) *Service {
	return &Service{cfg: cfg, repos: func() (authRepo, error) { return repo, nil }}
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

	pair, err := s.mintPair(clientAccountID)
	if err != nil {
		return TokenPair{}, User{}, err
	}
	return pair, user, nil
}

// Refresh mints a new access token from a still-valid refresh token,
// without requiring the user to sign another SEP-10 challenge.
func (s *Service) Refresh(refreshToken string) (TokenPair, error) {
	claims, err := authx.VerifyJWT(refreshToken, s.cfg.JWTPublicKey)
	if err != nil || claims.Subject != "refresh" {
		return TokenPair{}, errInvalidToken
	}
	return s.mintPair(claims.StellarAccount)
}

func (s *Service) mintPair(stellarAccount string) (TokenPair, error) {
	now := time.Now()
	access := authx.Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(now.Add(accessTokenTTL)),
			IssuedAt:  jwt.NewNumericDate(now),
			Subject:   "access", // authx.VerifyAccessToken requires this — a refresh token must never work as a bearer token
		},
		StellarAccount: stellarAccount,
	}
	refresh := authx.Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(now.Add(refreshTokenTTL)),
			IssuedAt:  jwt.NewNumericDate(now),
			Subject:   "refresh",
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
