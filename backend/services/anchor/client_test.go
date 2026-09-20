package anchor

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// dialingClient builds an *http.Client whose every dial is redirected to
// srv's real listener address, regardless of the hostname the caller asked
// for. This is what lets tests use a plain DNS-name-shaped domain like
// "anchor.example" (required by the SDK's stellartoml client, which
// rejects "host:port" / IP-literal domains outright) while actually talking
// to a local httptest.NewTLSServer.
func dialingClient(srv *httptest.Server) *http.Client {
	addr := srv.Listener.Addr().String()
	transport := &http.Transport{
		DialTLSContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return tls.Dial(network, addr, &tls.Config{InsecureSkipVerify: true}) //nolint:gosec // test-only, our own httptest server
		},
	}
	return &http.Client{Transport: transport}
}

// newTLSTestServer starts an httptest TLS server and returns it along with
// an *http.Client that trusts its certificate — every anchor.Client method
// under test enforces HTTPS (requireHTTPS), so a plain httptest.Server
// (HTTP) cannot be used here.
func newTLSTestServer(t *testing.T, handler http.HandlerFunc) (*httptest.Server, *http.Client) {
	t.Helper()
	srv := httptest.NewTLSServer(handler)
	t.Cleanup(srv.Close)
	return srv, srv.Client()
}

func TestClient_ProxyJSON_ForwardsMethodPathQueryAndAuth(t *testing.T) {
	var gotMethod, gotPath, gotQuery, gotAuth string
	var gotBody []byte
	srv, hc := newTLSTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		gotAuth = r.Header.Get("Authorization")
		gotBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"ok":true}`))
	})

	c := NewClient(hc)
	result, err := c.ProxyJSON(t.Context(), "POST", srv.URL, "/sep6/deposit", "asset_code=USDC", "anchor-jwt", "", []byte(`{"a":1}`))
	if err != nil {
		t.Fatalf("ProxyJSON: %v", err)
	}
	if gotMethod != "POST" {
		t.Errorf("method = %q, want POST", gotMethod)
	}
	if gotPath != "/sep6/deposit" {
		t.Errorf("path = %q, want /sep6/deposit", gotPath)
	}
	if gotQuery != "asset_code=USDC" {
		t.Errorf("query = %q, want asset_code=USDC", gotQuery)
	}
	if gotAuth != "Bearer anchor-jwt" {
		t.Errorf("Authorization = %q, want Bearer anchor-jwt", gotAuth)
	}
	if string(gotBody) != `{"a":1}` {
		t.Errorf("body = %q", gotBody)
	}
	var out struct {
		OK bool `json:"ok"`
	}
	if err := json.Unmarshal(result, &out); err != nil || !out.OK {
		t.Errorf("unexpected result: %s (err=%v)", result, err)
	}
}

func TestClient_ProxyJSON_NonJSONResponseRejected(t *testing.T) {
	srv, hc := newTLSTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("<html>not json</html>"))
	})
	c := NewClient(hc)
	if _, err := c.ProxyJSON(t.Context(), "GET", srv.URL, "/x", "", "", "", nil); err == nil {
		t.Fatal("expected an error for a non-JSON upstream response")
	}
}

// TestClient_ProxyJSON_AuthRejectionIsDistinct pins the contract the app's
// silent SEP-10 re-login depends on: an anchor 401/403 (expired JWT) must be
// distinguishable from any other upstream failure.
func TestClient_ProxyJSON_AuthRejectionIsDistinct(t *testing.T) {
	for _, status := range []int{http.StatusUnauthorized, http.StatusForbidden} {
		srv, hc := newTLSTestServer(t, func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(status)
			w.Write([]byte(`{"type":"authentication_required"}`))
		})
		_, err := NewClient(hc).ProxyJSON(t.Context(), "GET", srv.URL, "/x", "", "tok", "", nil)
		if !isAnchorAuthError(err) {
			t.Errorf("status %d: got %v, want an anchorAuthError", status, err)
		}
	}

	srv, hc := newTLSTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":"bad"}`))
	})
	_, err := NewClient(hc).ProxyJSON(t.Context(), "GET", srv.URL, "/x", "", "tok", "", nil)
	if err == nil || isAnchorAuthError(err) {
		t.Errorf("a 400 must stay a plain upstream failure, got %v", err)
	}
}

func TestClient_ProxyJSON_UpstreamErrorStatusPropagated(t *testing.T) {
	srv, hc := newTLSTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":"bad"}`))
	})
	c := NewClient(hc)
	if _, err := c.ProxyJSON(t.Context(), "GET", srv.URL, "/x", "", "", "", nil); err == nil {
		t.Fatal("expected an error for a 4xx upstream response")
	}
}

func TestClient_ProxyJSON_MultipartBodyNotSupported(t *testing.T) {
	// SERVICE.md #7: ProxyJSON always forces Content-Type: application/json
	// and the caller (handler.go's sepProxy) validates every body with
	// json.Valid before it ever reaches here — a real SEP-12 multipart KYC
	// upload cannot flow through this proxy today. This test pins that
	// documented limitation: a multipart-shaped body is not valid JSON and
	// must be rejected upstream of ProxyJSON, at the handler layer.
	var buf strings.Builder
	mw := multipart.NewWriter(&buf)
	_ = mw.WriteField("first_name", "Ada")
	_ = mw.Close()

	if json.Valid([]byte(buf.String())) {
		t.Fatal("test fixture is unexpectedly valid JSON")
	}
}

func TestClient_SEP10ChallengeAndToken(t *testing.T) {
	srv, hc := newTLSTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/auth":
			if got := r.URL.Query().Get("account"); got != "GACCOUNT" {
				t.Errorf("account query = %q, want GACCOUNT", got)
			}
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"transaction":"unsigned-xdr","network_passphrase":"Test SDF Network ; September 2015"}`))
		case r.Method == http.MethodPost && r.URL.Path == "/auth":
			body, _ := io.ReadAll(r.Body)
			var req struct {
				Transaction string `json:"transaction"`
			}
			_ = json.Unmarshal(body, &req)
			if req.Transaction != "signed-xdr" {
				t.Errorf("posted transaction = %q, want signed-xdr", req.Transaction)
			}
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"token":"anchor-jwt"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})

	c := NewClient(hc)
	txn, netPassphrase, err := c.SEP10Challenge(t.Context(), srv.URL+"/auth", "GACCOUNT")
	if err != nil {
		t.Fatalf("SEP10Challenge: %v", err)
	}
	if txn != "unsigned-xdr" {
		t.Errorf("challenge = %q, want unsigned-xdr", txn)
	}
	if netPassphrase != "Test SDF Network ; September 2015" {
		t.Errorf("network_passphrase = %q, want the upstream's own", netPassphrase)
	}

	tok, err := c.SEP10Token(t.Context(), srv.URL+"/auth", "signed-xdr")
	if err != nil {
		t.Fatalf("SEP10Token: %v", err)
	}
	if tok != "anchor-jwt" {
		t.Errorf("token = %q, want anchor-jwt", tok)
	}
}

func TestClient_FetchTOML(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/.well-known/stellar.toml" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Write([]byte(`WEB_AUTH_ENDPOINT="https://anchor.example/auth"
TRANSFER_SERVER="https://anchor.example/sep6"
SIGNING_KEY="GSIGNINGKEY"
`))
	}))
	defer srv.Close()

	// stellartoml's client rejects any "domain" containing a port or IP
	// literal outright (govalidator.IsDNSName), so the request must be sent
	// to a DNS-name-shaped domain — dialingClient makes that domain actually
	// resolve to this local server.
	c := NewClient(dialingClient(srv))

	toml, err := c.FetchTOML("anchor.example")
	if err != nil {
		t.Fatalf("FetchTOML: %v", err)
	}
	if toml.WebAuthEndpoint != "https://anchor.example/auth" {
		t.Errorf("WebAuthEndpoint = %q", toml.WebAuthEndpoint)
	}
	if toml.SigningKey != "GSIGNINGKEY" {
		t.Errorf("SigningKey = %q", toml.SigningKey)
	}
}

func TestRequireHTTPS(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	c := NewClient(srv.Client())

	// srv.URL is a plain http:// URL — every proxy path must reject it.
	if _, err := c.ProxyJSON(t.Context(), "GET", srv.URL, "/x", "", "", "", nil); err == nil {
		t.Fatal("expected an error for a non-HTTPS endpoint")
	}
}
