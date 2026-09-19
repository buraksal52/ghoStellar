package anchor

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/BurntSushi/toml"
	"github.com/stellar/go-stellar-sdk/clients/stellartoml"

	"github.com/local-payment/backend/pkg/nethost"
)

// Client is pay-anchor-service's only outbound HTTP surface — every call
// goes through hc, which the caller (cmd/anchorsvc/main.go) wraps with
// pkg/nethost's allow-list containing ONLY the operator-configured anchor
// domain(s), never a domain from user input (architecture.md §10, and the
// plan's "Anchor id → base URL eşlemesi konfigürasyondan gelir").
type Client struct {
	hc *http.Client
}

func NewClient(hc *http.Client) *Client {
	return &Client{hc: hc}
}

// AllowHost grows this client's SSRF allow-list to also permit host. Used
// once an anchor's own SEP-1 toml has been resolved and is found to
// legitimately delegate SEP-6/10/38 traffic to a different host than the
// bare ANCHOR_DOMAIN used to fetch it — a common, real-world anchor
// topology (see docs/reference/platform/anchor-entegrasyonu.md). The host
// being added still came from the operator-configured anchor's OWN
// published configuration, never from a request.
func (c *Client) AllowHost(host string) {
	nethost.AddAllowedHost(c.hc, host)
}

// FetchTOML resolves domain's SEP-1 stellar.toml.
func (c *Client) FetchTOML(domain string) (*stellartoml.Response, error) {
	tc := &stellartoml.Client{HTTP: c.hc}
	resp, err := tc.GetStellarToml(domain)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", ErrTomlUnavailable, err)
	}
	return resp, nil
}

func (c *Client) FetchQuoteServer(domain string) (string, error) {
	u := "https://" + domain + stellartoml.WellKnownPath
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return "", err
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return "", fmt.Errorf("%s: %w", ErrTomlUnavailable, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("%s: stellar.toml returned %d", ErrTomlUnavailable, resp.StatusCode)
	}
	var fields struct {
		AnchorQuoteServer string `toml:"ANCHOR_QUOTE_SERVER"`
	}
	if _, err := toml.NewDecoder(io.LimitReader(resp.Body, stellartoml.StellarTomlMaxSize)).Decode(&fields); err != nil {
		return "", fmt.Errorf("%s: parse ANCHOR_QUOTE_SERVER: %w", ErrTomlUnavailable, err)
	}
	return fields.AnchorQuoteServer, nil
}

// SEP10Challenge relays the anchor's own SEP-10 challenge back to the
// caller verbatim — this is the anchor's challenge, not ours (see
// docs/reference/platform/anchor-entegrasyonu.md's "İki ayrı SEP-10
// bağlamı").
func (c *Client) SEP10Challenge(ctx context.Context, webAuthEndpoint, account string) (string, error) {
	u, err := url.Parse(webAuthEndpoint)
	if err != nil {
		return "", fmt.Errorf("%s: bad WEB_AUTH_ENDPOINT: %w", ErrUpstreamFailed, err)
	}
	if err := requireHTTPS(u); err != nil {
		return "", err
	}
	q := u.Query()
	q.Set("account", account)
	u.RawQuery = q.Encode()

	var body struct {
		Transaction string `json:"transaction"`
	}
	if err := c.getJSON(ctx, u.String(), &body); err != nil {
		return "", err
	}
	return body.Transaction, nil
}

// SEP10Token exchanges a client-signed challenge for the anchor's own JWT.
// pay-anchor-service never stores this token — it is returned straight to
// the device.
func (c *Client) SEP10Token(ctx context.Context, webAuthEndpoint, signedTransaction string) (string, error) {
	var out struct {
		Token string `json:"token"`
	}
	payload, _ := json.Marshal(map[string]string{"transaction": signedTransaction})
	if err := c.postJSON(ctx, webAuthEndpoint, "", payload, &out); err != nil {
		return "", err
	}
	return out.Token, nil
}

// SEP24Interactive starts a deposit or withdraw interactive flow. kind is
// "deposit" or "withdraw"; anchorToken is the device's own SEP-10 token for
// THIS anchor (never persisted).
func (c *Client) SEP24Interactive(ctx context.Context, transferServer, kind, anchorToken, assetCode, account string) (id, interactiveURL string, err error) {
	u := strings.TrimRight(transferServer, "/") + "/transactions/" + kind + "/interactive"
	payload, _ := json.Marshal(map[string]string{"asset_code": assetCode, "account": account})

	var out struct {
		Type string `json:"type"`
		URL  string `json:"url"`
		ID   string `json:"id"`
	}
	if err := c.postJSON(ctx, u, anchorToken, payload, &out); err != nil {
		return "", "", err
	}
	return out.ID, out.URL, nil
}

// SEP24Transactions proxies a read of the anchor's own transaction list —
// the device could call the anchor directly with its own token just as
// well; going through us keeps one API surface and one SSRF-safe egress
// point.
func (c *Client) SEP24Transactions(ctx context.Context, transferServer, anchorToken, assetCode string) (json.RawMessage, error) {
	u := strings.TrimRight(transferServer, "/") + "/transactions?asset_code=" + url.QueryEscape(assetCode)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+anchorToken)
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", ErrUpstreamFailed, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("%s: anchor returned %d: %s", ErrUpstreamFailed, resp.StatusCode, string(body))
	}
	return body, nil
}

// ProxyJSON forwards a SEP call to a server discovered from the configured
// anchor's stellar.toml. The outbound client's hostname guard remains the
// authority for which hosts can be reached.
func (c *Client) ProxyJSON(ctx context.Context, method, base, path, rawQuery, bearer string, payload []byte) (json.RawMessage, error) {
	u, err := url.Parse(strings.TrimRight(base, "/") + "/" + strings.TrimLeft(path, "/"))
	if err != nil {
		return nil, fmt.Errorf("%s: bad SEP endpoint: %w", ErrUpstreamFailed, err)
	}
	if err := requireHTTPS(u); err != nil {
		return nil, err
	}
	u.RawQuery = rawQuery
	var body io.Reader
	if payload != nil {
		body = strings.NewReader(string(payload))
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return nil, err
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", ErrUpstreamFailed, err)
	}
	defer resp.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("%s: anchor returned %d: %s", ErrUpstreamFailed, resp.StatusCode, string(responseBody))
	}
	if !json.Valid(responseBody) {
		return nil, fmt.Errorf("%s: anchor returned invalid JSON", ErrUpstreamFailed)
	}
	return json.RawMessage(responseBody), nil
}

func (c *Client) getJSON(ctx context.Context, u string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("%s: %w", ErrUpstreamFailed, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("%s: anchor returned %d", ErrUpstreamFailed, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *Client) postJSON(ctx context.Context, u, bearer string, payload []byte, out any) error {
	parsed, err := url.Parse(u)
	if err != nil {
		return err
	}
	if err := requireHTTPS(parsed); err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, strings.NewReader(string(payload)))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("%s: %w", ErrUpstreamFailed, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return fmt.Errorf("%s: anchor returned %d: %s", ErrUpstreamFailed, resp.StatusCode, string(body))
	}
	return json.Unmarshal(body, out)
}

func requireHTTPS(u *url.URL) error {
	if u == nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		return fmt.Errorf("%s: anchor endpoint must use HTTPS and contain no credentials", ErrUpstreamFailed)
	}
	return nil
}
