package anchor

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/local-payment/backend/pkg/authx"
)

// bearerHandler wraps next with a real authx.RequireBearer backed by a
// throwaway RSA key and returns a signed access token for address — since
// authx's claims context key is unexported, this is the only way to get a
// request through with the right caller identity.
func bearerHandler(t *testing.T, address string, next http.Handler) (http.Handler, string) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
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
		t.Fatal(err)
	}
	wrapped := authx.RequireBearer(&priv.PublicKey, "", func(w http.ResponseWriter) {
		w.WriteHeader(http.StatusUnauthorized)
	}, next)
	return wrapped, tok
}

func TestSepProxy_DepositAccountMismatchRejected(t *testing.T) {
	client := tomlServer(t, `TRANSFER_SERVER="https://api.anchor.example/sep6"`)
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), client, nil, discardLogger())
	h := NewHandler(svc, discardLogger())

	mux := http.NewServeMux()
	RegisterRoutes(mux, h)
	wrapped, tok := bearerHandler(t, "GCALLERADDRESS000000000000000000000000000000000000000", mux)

	req := httptest.NewRequest("GET", "/anchors/"+testAnchorID+"/sep6/deposit?account=GSOMEONEELSE00000000000000000000000000000000000000000", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("X-Anchor-Token", "anchor-jwt")
	rec := httptest.NewRecorder()
	wrapped.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("got status %d, want 403; body=%s", rec.Code, rec.Body.String())
	}
}

func TestSepProxy_MissingAnchorTokenRejected(t *testing.T) {
	client := tomlServer(t, `TRANSFER_SERVER="https://api.anchor.example/sep6"`)
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), client, nil, discardLogger())
	h := NewHandler(svc, discardLogger())

	mux := http.NewServeMux()
	RegisterRoutes(mux, h)
	address := "GCALLERADDRESS000000000000000000000000000000000000000"
	wrapped, tok := bearerHandler(t, address, mux)

	req := httptest.NewRequest("GET", "/anchors/"+testAnchorID+"/sep6/withdraw", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	// No X-Anchor-Token set.
	rec := httptest.NewRecorder()
	wrapped.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got status %d, want 401; body=%s", rec.Code, rec.Body.String())
	}
	var env struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &env)
	if env.Error.Code != ErrAuthRequired {
		t.Errorf("error code = %q, want %q", env.Error.Code, ErrAuthRequired)
	}
}

func TestSepProxy_MalformedJSONBodyRejected(t *testing.T) {
	client := tomlServer(t, `KYC_SERVER="https://kyc.anchor.example/sep12"`)
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), client, nil, discardLogger())
	h := NewHandler(svc, discardLogger())

	mux := http.NewServeMux()
	RegisterRoutes(mux, h)
	wrapped, tok := bearerHandler(t, "GCALLERADDRESS000000000000000000000000000000000000000", mux)

	req := httptest.NewRequest("POST", "/anchors/"+testAnchorID+"/sep12/customer", strings.NewReader("{not-json"))
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("X-Anchor-Token", "anchor-jwt")
	rec := httptest.NewRecorder()
	wrapped.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got status %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

// TestSepProxy_MultipartBodyPassedThrough closes SERVICE.md #7: a real
// SEP-12 multipart/form-data KYC upload must flow through this proxy
// byte-for-byte with its original Content-Type (including the boundary),
// not be forced into application/json or rejected by json.Valid.
func TestSepProxy_MultipartBodyPassedThrough(t *testing.T) {
	var gotContentType string
	var gotBody []byte
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/stellar.toml":
			w.Write([]byte(`KYC_SERVER="https://` + testAnchorDomain + `/sep12"`))
		case "/sep12/customer":
			gotContentType = r.Header.Get("Content-Type")
			gotBody, _ = io.ReadAll(r.Body)
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"id":"customer-1"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), NewClient(dialingClient(srv)), nil, discardLogger())
	h := NewHandler(svc, discardLogger())

	mux := http.NewServeMux()
	RegisterRoutes(mux, h)
	wrapped, tok := bearerHandler(t, "GCALLERADDRESS000000000000000000000000000000000000000", mux)

	body := "--boundary\r\nContent-Disposition: form-data; name=\"first_name\"\r\n\r\nAda\r\n--boundary--\r\n"
	req := httptest.NewRequest("PUT", "/anchors/"+testAnchorID+"/sep12/customer", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("X-Anchor-Token", "anchor-jwt")
	req.Header.Set("Content-Type", "multipart/form-data; boundary=boundary")
	rec := httptest.NewRecorder()
	wrapped.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if gotContentType != "multipart/form-data; boundary=boundary" {
		t.Errorf("upstream Content-Type = %q, want the original multipart Content-Type preserved", gotContentType)
	}
	if string(gotBody) != body {
		t.Errorf("upstream body = %q, want %q (byte-for-byte passthrough)", gotBody, body)
	}
}

// TestSepProxy_MalformedJSONStillRejectedForOrdinaryRequests proves the
// json.Valid check is only skipped for multipart bodies — an ordinary
// (non-multipart) malformed body is still rejected, matching
// TestSepProxy_MalformedJSONBodyRejected above.
func TestSepProxy_MalformedJSONStillRejectedForOrdinaryRequests(t *testing.T) {
	client := tomlServer(t, `KYC_SERVER="https://kyc.anchor.example/sep12"`)
	cfg := testConfig(testAnchorDomain, testIssuer(t))
	svc := newServiceWithRepo(cfg, newFakeRepo(), client, nil, discardLogger())
	h := NewHandler(svc, discardLogger())

	mux := http.NewServeMux()
	RegisterRoutes(mux, h)
	wrapped, tok := bearerHandler(t, "GCALLERADDRESS000000000000000000000000000000000000000", mux)

	req := httptest.NewRequest("PUT", "/anchors/"+testAnchorID+"/sep12/customer", strings.NewReader("{not-json"))
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("X-Anchor-Token", "anchor-jwt")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	wrapped.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("got status %d, want 400", rec.Code)
	}
}
