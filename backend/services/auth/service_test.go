package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"errors"
	"log/slog"
	"testing"

	"github.com/stellar/go-stellar-sdk/keypair"
	"github.com/stellar/go-stellar-sdk/txnbuild"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/dbx"
	"github.com/local-payment/backend/ports"
	"github.com/local-payment/backend/ports/portstest"
)

const testPassphrase = "Test SDF Network ; September 2015"

// discardLogger mirrors services/anchor's test helper of the same name —
// a *slog.Logger that writes nowhere, so tests that must exercise a
// best-effort warn-and-continue path don't spam test output.
func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(discardWriter{}, nil))
}

type discardWriter struct{}

func (discardWriter) Write(p []byte) (int, error) { return len(p), nil }

func testJWTKeys(t *testing.T) (*rsa.PrivateKey, *rsa.PublicKey) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return priv, &priv.PublicKey
}

func testServiceAndServer(t *testing.T) (*Service, *keypair.Full) {
	t.Helper()
	return testServiceAndServerWithChain(t, nil, false)
}

// testServiceAndServerWithChain is testServiceAndServer but lets fund-path
// tests wire in a fake ports.ChainGateway and toggle FundNewAccounts.
func testServiceAndServerWithChain(t *testing.T, chain ports.ChainGateway, fundNewAccounts bool) (*Service, *keypair.Full) {
	t.Helper()
	serverKP, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	priv, pub := testJWTKeys(t)
	cfg := Config{
		ServerSigningSeed: serverKP.Seed(),
		HomeDomain:        "example.com",
		WebAuthDomain:     "example.com",
		NetworkPassphrase: testPassphrase,
		JWTPrivateKey:     priv,
		JWTPublicKey:      pub,
		FundNewAccounts:   fundNewAccounts,
	}
	return newServiceWithRepo(cfg, newFakeRepo(), chain, discardLogger()), serverKP
}

// signChallenge decodes the unsigned challenge XDR Challenge() returned and
// re-encodes it with an additional signature from signer — exactly what the
// client device does before posting to /auth/token.
func signChallenge(t *testing.T, unsignedXDR string, signer *keypair.Full) string {
	t.Helper()
	tx, err := txnbuild.TransactionFromXDR(unsignedXDR)
	if err != nil {
		t.Fatalf("decode challenge XDR: %v", err)
	}
	simple, ok := tx.Transaction()
	if !ok {
		t.Fatal("challenge tx is not a simple transaction")
	}
	signed, err := simple.Sign(testPassphrase, signer)
	if err != nil {
		t.Fatalf("sign challenge: %v", err)
	}
	out, err := signed.Base64()
	if err != nil {
		t.Fatalf("encode signed challenge: %v", err)
	}
	return out
}

func TestChallenge_ReadableByReadChallengeTx(t *testing.T) {
	svc, serverKP := testServiceAndServer(t)
	clientKP, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}

	unsignedXDR, err := svc.Challenge(clientKP.Address())
	if err != nil {
		t.Fatalf("Challenge: %v", err)
	}

	_, gotClientID, _, _, err := txnbuild.ReadChallengeTx(unsignedXDR, serverKP.Address(), testPassphrase, "example.com", []string{"example.com"})
	if err != nil {
		t.Fatalf("ReadChallengeTx: %v", err)
	}
	if gotClientID != clientKP.Address() {
		t.Fatalf("client account = %q, want %q", gotClientID, clientKP.Address())
	}
}

func TestVerifyAndMint_HappyPath(t *testing.T) {
	svc, _ := testServiceAndServer(t)
	clientKP, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}

	unsignedXDR, err := svc.Challenge(clientKP.Address())
	if err != nil {
		t.Fatalf("Challenge: %v", err)
	}
	signedXDR := signChallenge(t, unsignedXDR, clientKP)

	pair, user, err := svc.VerifyAndMint(context.Background(), signedXDR)
	if err != nil {
		t.Fatalf("VerifyAndMint: %v", err)
	}
	if user.StellarAddress != clientKP.Address() {
		t.Errorf("user address = %q, want %q", user.StellarAddress, clientKP.Address())
	}
	if pair.AccessToken == "" || pair.RefreshToken == "" {
		t.Error("expected both access and refresh tokens to be non-empty")
	}

	// The minted access token must pass VerifyAccessToken (sub=access)...
	claims, err := authx.VerifyAccessToken(pair.AccessToken, svc.cfg.JWTPublicKey, "")
	if err != nil {
		t.Fatalf("access token failed VerifyAccessToken: %v", err)
	}
	if claims.StellarAccount != clientKP.Address() {
		t.Errorf("access token account = %q, want %q", claims.StellarAccount, clientKP.Address())
	}
	// ...but the refresh token must NOT (it must never work as a bearer token).
	if _, err := authx.VerifyAccessToken(pair.RefreshToken, svc.cfg.JWTPublicKey, ""); err == nil {
		t.Error("refresh token must be rejected by VerifyAccessToken")
	}
}

func TestVerifyAndMint_WrongSignerRejected(t *testing.T) {
	svc, _ := testServiceAndServer(t)
	clientKP, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	impostor, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}

	unsignedXDR, err := svc.Challenge(clientKP.Address())
	if err != nil {
		t.Fatalf("Challenge: %v", err)
	}
	// Signed by the WRONG key — the challenge was issued for clientKP.
	signedXDR := signChallenge(t, unsignedXDR, impostor)

	_, _, err = svc.VerifyAndMint(context.Background(), signedXDR)
	if !errors.Is(err, errInvalidSignature) {
		t.Fatalf("got %v, want errInvalidSignature", err)
	}
}

func TestVerifyAndMint_MalformedChallengeRejected(t *testing.T) {
	svc, _ := testServiceAndServer(t)
	_, _, err := svc.VerifyAndMint(context.Background(), "not-a-valid-xdr")
	if !errors.Is(err, errInvalidChallenge) {
		t.Fatalf("got %v, want errInvalidChallenge", err)
	}
}

func TestRefresh_AcceptsRefreshRejectsAccess(t *testing.T) {
	svc, _ := testServiceAndServer(t)
	address := "GADDRXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
	pair, err := svc.mintPair(address)
	if err != nil {
		t.Fatalf("mintPair: %v", err)
	}

	// Refresh must succeed with the refresh token...
	newPair, err := svc.Refresh(pair.RefreshToken)
	if err != nil {
		t.Fatalf("Refresh with refresh token: %v", err)
	}
	if newPair.AccessToken == "" {
		t.Error("expected a fresh access token")
	}

	// ...but must reject the access token used as if it were a refresh token.
	if _, err := svc.Refresh(pair.AccessToken); !errors.Is(err, errInvalidToken) {
		t.Fatalf("got %v, want errInvalidToken when refreshing with an access token", err)
	}
}

func TestGetProfile_NotFound(t *testing.T) {
	svc, _ := testServiceAndServer(t)
	_, err := svc.GetProfile(context.Background(), "GUNKNOWN")
	if !errors.Is(err, errFakeUserNotFound) {
		t.Fatalf("got %v, want errFakeUserNotFound", err)
	}
}

func TestService_DBNotReady(t *testing.T) {
	pool := &dbx.Pool{} // never connected
	priv, pub := testJWTKeys(t)
	svc := NewService(Config{JWTPrivateKey: priv, JWTPublicKey: pub, NetworkPassphrase: testPassphrase}, pool, nil, discardLogger())

	_, err := svc.GetProfile(context.Background(), "GADDR")
	if !errors.Is(err, ErrDBNotReady) {
		t.Fatalf("got %v, want ErrDBNotReady", err)
	}
}

// loginAndSignChallenge drives a full Challenge -> sign -> VerifyAndMint
// round trip and returns the address logged in with — the shared setup for
// every fundIfNeeded test below.
func loginAndSignChallenge(t *testing.T, svc *Service) (string, TokenPair, error) {
	t.Helper()
	clientKP, err := keypair.Random()
	if err != nil {
		t.Fatal(err)
	}
	unsignedXDR, err := svc.Challenge(clientKP.Address())
	if err != nil {
		t.Fatalf("Challenge: %v", err)
	}
	signedXDR := signChallenge(t, unsignedXDR, clientKP)
	pair, _, err := svc.VerifyAndMint(context.Background(), signedXDR)
	return clientKP.Address(), pair, err
}

func TestVerifyAndMint_FundsNewAccountOnChain(t *testing.T) {
	chain := &portstest.FakeChain{
		GetAccountFunc: func(ctx context.Context, address string) (ports.AccountInfo, error) {
			return ports.AccountInfo{Address: address, Exists: false}, nil
		},
	}
	svc, _ := testServiceAndServerWithChain(t, chain, true)

	_, pair, err := loginAndSignChallenge(t, svc)
	if err != nil {
		t.Fatalf("VerifyAndMint: %v", err)
	}
	if pair.AccessToken == "" {
		t.Error("expected a successful login even though the account needed funding")
	}
	if chain.GetAccountCalls != 1 {
		t.Errorf("GetAccountCalls = %d, want 1", chain.GetAccountCalls)
	}
	if chain.FundCalls != 1 {
		t.Errorf("FundCalls = %d, want 1", chain.FundCalls)
	}
}

func TestVerifyAndMint_SkipsFriendbotWhenAccountAlreadyExists(t *testing.T) {
	chain := &portstest.FakeChain{
		GetAccountFunc: func(ctx context.Context, address string) (ports.AccountInfo, error) {
			return ports.AccountInfo{Address: address, Exists: true}, nil
		},
	}
	svc, _ := testServiceAndServerWithChain(t, chain, true)

	_, _, err := loginAndSignChallenge(t, svc)
	if err != nil {
		t.Fatalf("VerifyAndMint: %v", err)
	}
	if chain.FundCalls != 0 {
		t.Errorf("FundCalls = %d, want 0 (account already exists)", chain.FundCalls)
	}
}

func TestVerifyAndMint_LoginSucceedsWhenFriendbotFails(t *testing.T) {
	chain := &portstest.FakeChain{
		GetAccountFunc: func(ctx context.Context, address string) (ports.AccountInfo, error) {
			return ports.AccountInfo{Address: address, Exists: false}, nil
		},
		FundFunc: func(ctx context.Context, address string) error {
			return errors.New("friendbot: rate limited")
		},
	}
	svc, _ := testServiceAndServerWithChain(t, chain, true)

	_, pair, err := loginAndSignChallenge(t, svc)
	if err != nil {
		t.Fatalf("VerifyAndMint: %v (login must succeed even when friendbot fails)", err)
	}
	if pair.AccessToken == "" {
		t.Error("expected a non-empty access token despite the fund failure")
	}
	if chain.FundCalls != 1 {
		t.Errorf("FundCalls = %d, want 1", chain.FundCalls)
	}
}

func TestVerifyAndMint_FundDisabledNeverTouchesChain(t *testing.T) {
	chain := &portstest.FakeChain{}
	svc, _ := testServiceAndServerWithChain(t, chain, false)

	_, _, err := loginAndSignChallenge(t, svc)
	if err != nil {
		t.Fatalf("VerifyAndMint: %v", err)
	}
	if chain.GetAccountCalls != 0 {
		t.Errorf("GetAccountCalls = %d, want 0 (FundNewAccounts is false)", chain.GetAccountCalls)
	}
	if chain.FundCalls != 0 {
		t.Errorf("FundCalls = %d, want 0 (FundNewAccounts is false)", chain.FundCalls)
	}
}

// ---- FundOwnAccount (the manual "Fund with testnet XLM" action) -----------

func TestFundOwnAccount_CallsFriendbotUnconditionally(t *testing.T) {
	chain := &portstest.FakeChain{
		GetAccountFunc: func(ctx context.Context, address string) (ports.AccountInfo, error) {
			// Unlike fundIfNeeded, FundOwnAccount must not even check this —
			// an explicit "fund me" action always tries.
			return ports.AccountInfo{Address: address, Exists: true}, nil
		},
	}
	svc, _ := testServiceAndServerWithChain(t, chain, true)

	funded, err := svc.FundOwnAccount(context.Background(), "GADDR")
	if err != nil {
		t.Fatalf("FundOwnAccount: %v", err)
	}
	if !funded {
		t.Error("funded = false, want true")
	}
	if chain.GetAccountCalls != 0 {
		t.Errorf("GetAccountCalls = %d, want 0 (FundOwnAccount never checks Exists)", chain.GetAccountCalls)
	}
	if chain.FundCalls != 1 {
		t.Errorf("FundCalls = %d, want 1", chain.FundCalls)
	}
}

func TestFundOwnAccount_DisabledOnNonTestnetDeployments(t *testing.T) {
	chain := &portstest.FakeChain{}
	svc, _ := testServiceAndServerWithChain(t, chain, false)

	funded, err := svc.FundOwnAccount(context.Background(), "GADDR")
	if err != nil {
		t.Fatalf("FundOwnAccount: %v (must never error, even when unavailable)", err)
	}
	if funded {
		t.Error("funded = true, want false when FundNewAccounts is off")
	}
	if chain.FundCalls != 0 {
		t.Errorf("FundCalls = %d, want 0", chain.FundCalls)
	}
}

func TestFundOwnAccount_FriendbotFailureIsReportedNotThrown(t *testing.T) {
	chain := &portstest.FakeChain{
		FundFunc: func(ctx context.Context, address string) error {
			return errors.New("friendbot: rate limited")
		},
	}
	svc, _ := testServiceAndServerWithChain(t, chain, true)

	funded, err := svc.FundOwnAccount(context.Background(), "GADDR")
	if err != nil {
		t.Fatalf("FundOwnAccount: %v (best-effort — must not surface as an error)", err)
	}
	if funded {
		t.Error("funded = true, want false when the friendbot call itself failed")
	}
}

func TestFundOwnAccount_NoChainGateway(t *testing.T) {
	svc, _ := testServiceAndServer(t) // chain=nil, FundNewAccounts=false

	funded, err := svc.FundOwnAccount(context.Background(), "GADDR")
	if err != nil {
		t.Fatalf("FundOwnAccount: %v", err)
	}
	if funded {
		t.Error("funded = true, want false with no chain gateway wired")
	}
}
