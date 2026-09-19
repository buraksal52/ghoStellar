package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"errors"
	"testing"

	"github.com/stellar/go-stellar-sdk/keypair"
	"github.com/stellar/go-stellar-sdk/txnbuild"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/dbx"
)

const testPassphrase = "Test SDF Network ; September 2015"

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
	}
	return newServiceWithRepo(cfg, newFakeRepo()), serverKP
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
	claims, err := authx.VerifyAccessToken(pair.AccessToken, svc.cfg.JWTPublicKey)
	if err != nil {
		t.Fatalf("access token failed VerifyAccessToken: %v", err)
	}
	if claims.StellarAccount != clientKP.Address() {
		t.Errorf("access token account = %q, want %q", claims.StellarAccount, clientKP.Address())
	}
	// ...but the refresh token must NOT (it must never work as a bearer token).
	if _, err := authx.VerifyAccessToken(pair.RefreshToken, svc.cfg.JWTPublicKey); err == nil {
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
	svc := NewService(Config{JWTPrivateKey: priv, JWTPublicKey: pub, NetworkPassphrase: testPassphrase}, pool)

	_, err := svc.GetProfile(context.Background(), "GADDR")
	if !errors.Is(err, ErrDBNotReady) {
		t.Fatalf("got %v, want ErrDBNotReady", err)
	}
}
