package anchor

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/stellar/go-stellar-sdk/clients/stellartoml"
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

// FetchTOML resolves domain's SEP-1 stellar.toml.
func (c *Client) FetchTOML(domain string) (*stellartoml.Response, error) {
	tc := &stellartoml.Client{HTTP: c.hc}
	resp, err := tc.GetStellarToml(domain)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", ErrTomlUnavailable, err)
	}
	return resp, nil
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
