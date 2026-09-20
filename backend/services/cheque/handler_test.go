package cheque

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/local-payment/backend/pkg/authx"
	"github.com/local-payment/backend/pkg/httpx"
)

// ---- bearer-token test harness ---------------------------------------------
//
// authx.Claims can only be injected into a request context by
// authx.RequireBearer itself (the ctxKey is unexported), so every handler
// test that needs an authenticated caller wraps the handler under test with
// a real RequireBearer middleware backed by a throwaway RSA key, exactly as
// cmd/chequesvc/main.go does in production.

type bearerFixture struct {
	pubKey      *rsa.PublicKey
	accessToken string
	address     string
}

func newBearerFixture(t *testing.T) bearerFixture {
	t.Helper()
	return bearerFixtureFor(t, mustRandomAccount())
}

// bearerFixtureFor mints a fresh RSA key + signed access token whose
// `stellar_account` claim is pinned to address — needed so the "caller must
// be the cheque's own sender/receiver" checks in Service line up with a
// specific seeded cheque's parties.
func bearerFixtureFor(t *testing.T, address string) bearerFixture {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate RSA key: %v", err)
	}
	now := time.Now()
	claims := authx.Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(now.Add(time.Hour)),
			IssuedAt:  jwt.NewNumericDate(now),
			Subject:   "access",
		},
		StellarAccount: address,
	}
	tok, err := jwt.NewWithClaims(jwt.SigningMethodRS256, claims).SignedString(priv)
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	return bearerFixture{pubKey: &priv.PublicKey, accessToken: tok, address: address}
}

func (f bearerFixture) wrap(next http.Handler) http.Handler {
	return authx.RequireBearer(f.pubKey, "", unauthorizedTest, next)
}

func unauthorizedTest(w http.ResponseWriter) {
	httpx.WriteError(w, http.StatusUnauthorized, "auth.invalid_token", "missing or invalid bearer token", nil)
}

func doJSON(t *testing.T, h http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if raw, ok := body.(string); ok {
			buf.WriteString(raw)
		} else if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode body: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func newAPIMux(h *Handler) http.Handler {
	mux := http.NewServeMux()
	RegisterRoutes(mux, h)
	return mux
}

// ---- 401 on every route with no/invalid claims -----------------------------

func TestHandler_RequiresBearer(t *testing.T) {
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), fundedChain(t, 1))
	h := NewHandler(svc)
	f := newBearerFixture(t)
	mux := f.wrap(newAPIMux(h))

	routes := []struct{ method, path string }{
		{"POST", "/cheques"},
		{"POST", "/cheques/x/preauth"},
		{"POST", "/cheques/x/claim-xdr"},
		{"POST", "/cheques/x/force-collect-xdr"},
		{"POST", "/cheques/x/confirm-lock"},
		{"POST", "/cheques/x/confirm-claim"},
		{"POST", "/cheques/x/confirm-force-collect"},
		{"POST", "/cheques/x/ack"},
		{"GET", "/sync"},
		{"POST", "/pool/deposit-xdr"},
		{"POST", "/pool/withdraw-xdr"},
		{"POST", "/pool/confirm-deposit"},
		{"POST", "/pool/confirm-withdraw"},
	}
	for _, r := range routes {
		t.Run(r.method+" "+r.path, func(t *testing.T) {
			rec := doJSON(t, mux, r.method, r.path, "", nil)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("got status %d, want 401", rec.Code)
			}
		})
	}
}

// ---- malformed JSON bodies --------------------------------------------------

func TestHandler_MalformedJSONRejected(t *testing.T) {
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), fundedChain(t, 1))
	h := NewHandler(svc)
	f := newBearerFixture(t)
	mux := f.wrap(newAPIMux(h))

	routes := []struct{ method, path string }{
		{"POST", "/cheques"},
		{"POST", "/cheques/x/preauth"},
		{"POST", "/pool/deposit-xdr"},
		{"POST", "/pool/withdraw-xdr"},
		{"POST", "/pool/confirm-deposit"},
		{"POST", "/pool/confirm-withdraw"},
		// Fix 2: these three used to silently swallow a decode error.
		{"POST", "/cheques/x/confirm-lock"},
		{"POST", "/cheques/x/confirm-claim"},
		{"POST", "/cheques/x/confirm-force-collect"},
	}
	for _, r := range routes {
		t.Run(r.method+" "+r.path, func(t *testing.T) {
			rec := doJSON(t, mux, r.method, r.path, f.accessToken, "{not-json")
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("got status %d, want 400", rec.Code)
			}
		})
	}
}

// TestHandler_ConfirmLockAndClaim_EmptyBodyAllowed proves Fix 2 keeps
// backward compatibility with scripts/e2e.sh, which posts a literal '{}' to
// confirm-lock/confirm-claim with no txHash — that must still succeed.
func TestHandler_ConfirmLockAndClaim_EmptyBodyAllowed(t *testing.T) {
	senderFixture := bearerFixtureFor(t, testSender)
	receiverFixture := bearerFixtureFor(t, testReceiver)

	// Separate repos per sub-case: seedCheque's CreateReservedCheque enforces
	// the one-active-reservation-per-sender rule (D5), and both cases reuse
	// the same package-level testSender/testReceiver fixtures.
	lockRepo := newFakeRepo()
	lockSvc := newServiceWithRepo(testConfig(), lockRepo, fundedChain(t, 1))
	lockCheque := seedCheque(t, lockRepo, StateImzaliRezerve)
	mux := senderFixture.wrap(newAPIMux(NewHandler(lockSvc)))
	rec := doJSON(t, mux, "POST", "/cheques/"+lockCheque.ID+"/confirm-lock", senderFixture.accessToken, "{}")
	if rec.Code != http.StatusOK {
		t.Fatalf("confirm-lock with empty body: got %d, body=%s", rec.Code, rec.Body.String())
	}

	claimRepo := newFakeRepo()
	claimSvc := newServiceWithRepo(testConfig(), claimRepo, fundedChain(t, 1))
	claimCheque := seedCheque(t, claimRepo, StateHavuzda)
	mux2 := receiverFixture.wrap(newAPIMux(NewHandler(claimSvc)))
	rec2 := doJSON(t, mux2, "POST", "/cheques/"+claimCheque.ID+"/confirm-claim", receiverFixture.accessToken, "{}")
	if rec2.Code != http.StatusOK {
		t.Fatalf("confirm-claim with empty body: got %d, body=%s", rec2.Code, rec2.Body.String())
	}
}

// TestHandler_ConfirmForceCollect_MissingCollectedRejected is Fix 2's core
// regression test: before the fix, an empty/malformed body silently defaulted
// `collected` to false — bouncing a cheque that may have actually been
// collected. Now it must be rejected outright.
func TestHandler_ConfirmForceCollect_MissingCollectedRejected(t *testing.T) {
	repo := newFakeRepo()
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	h := NewHandler(svc)
	c := seedCheque(t, repo, StateZorlaTahsilDenendi)
	f := bearerFixtureFor(t, testReceiver)
	mux := f.wrap(newAPIMux(h))

	for _, body := range []any{"{}", nil, `{"txHash":"abc"}`} {
		rec := doJSON(t, mux, "POST", "/cheques/"+c.ID+"/confirm-force-collect", f.accessToken, body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("body %v: got status %d, want 400", body, rec.Code)
		}
	}

	// The correct shape must still work.
	rec := doJSON(t, mux, "POST", "/cheques/"+c.ID+"/confirm-force-collect", f.accessToken, map[string]any{"txHash": "abc", "collected": true})
	if rec.Code != http.StatusOK {
		t.Fatalf("valid confirm-force-collect: got %d, body=%s", rec.Code, rec.Body.String())
	}
}

// ---- writeChequeError status/code mapping ----------------------------------

func TestWriteChequeError_Mapping(t *testing.T) {
	tests := []struct {
		err        error
		wantStatus int
		wantCode   string
	}{
		{ErrDBNotReadyErr, http.StatusServiceUnavailable, ErrDBNotReady},
		{errInsufficientBalance, http.StatusUnprocessableEntity, ErrInsufficientBalance},
		{errAlreadyActive, http.StatusConflict, ErrAlreadyActive},
		{errInvalidReceiver, http.StatusBadRequest, ErrInvalidReceiver},
		{errReceiverNoTrustline, http.StatusUnprocessableEntity, ErrReceiverNoTrustline},
		{errSelfTransfer, http.StatusBadRequest, ErrSelfTransfer},
		{errInvalidAmount, http.StatusBadRequest, ErrInvalidAmount},
		{errExpired, http.StatusConflict, ErrExpired},
		{errTerminalState, http.StatusConflict, ErrTerminalState},
		{errNotFound, http.StatusNotFound, ErrNotFound},
		{errPoolWithdrawLocked, http.StatusConflict, ErrPoolWithdrawLocked},
		{errChainUnavailable, http.StatusBadGateway, ErrChainUnavailable},
		{errBadRequest, http.StatusBadRequest, ErrBadRequest},
	}
	for _, tc := range tests {
		t.Run(tc.wantCode, func(t *testing.T) {
			rec := httptest.NewRecorder()
			writeChequeError(rec, tc.err)
			if rec.Code != tc.wantStatus {
				t.Errorf("status = %d, want %d", rec.Code, tc.wantStatus)
			}
			var env httpx.ErrorEnvelope
			if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
				t.Fatalf("decode error envelope: %v", err)
			}
			if env.Error.Code != tc.wantCode {
				t.Errorf("code = %q, want %q", env.Error.Code, tc.wantCode)
			}
		})
	}
}

// ---- tap/scan payment requests (requestId) over HTTP ------------------------

func TestHandler_CreateCheque_RequestIDIsSingleUse(t *testing.T) {
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), fundedChain(t, 1))
	mux := newAPIMux(NewHandler(svc))

	first := bearerFixtureFor(t, testSender)
	second := bearerFixtureFor(t, mustRandomAccount())
	body := map[string]string{"receiver": testReceiver, "amount": "10", "requestId": "req-http-1"}

	rec := doJSON(t, first.wrap(mux), "POST", "/cheques", first.accessToken, body)
	if rec.Code != http.StatusCreated {
		t.Fatalf("first create: status %d, body %s", rec.Code, rec.Body.String())
	}

	rec = doJSON(t, second.wrap(mux), "POST", "/cheques", second.accessToken, body)
	if rec.Code != http.StatusConflict {
		t.Fatalf("second create: status %d, want 409; body %s", rec.Code, rec.Body.String())
	}
	var env struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Error.Code != ErrRequestUsed {
		t.Errorf("error code = %q, want %q", env.Error.Code, ErrRequestUsed)
	}
}

func TestHandler_CreateCheque_InvalidRequestIDIs400(t *testing.T) {
	svc := newServiceWithRepo(testConfig(), newFakeRepo(), fundedChain(t, 1))
	mux := newAPIMux(NewHandler(svc))
	f := bearerFixtureFor(t, testSender)

	rec := doJSON(t, f.wrap(mux), "POST", "/cheques", f.accessToken,
		map[string]string{"receiver": testReceiver, "amount": "10", "requestId": "no spaces allowed"})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, want 400; body %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), ErrInvalidRequestID) {
		t.Errorf("body %s does not carry %s", rec.Body.String(), ErrInvalidRequestID)
	}
}
