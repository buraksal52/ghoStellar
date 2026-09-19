// Package nethost guards every outbound HTTP call a service makes (Horizon,
// Soroban RPC, anchor SEP-1/SEP-10/SEP-24 endpoints) with a hostname
// allow-list, so a compromised or misconfigured dependency — or an
// anchor's SEP-1 toml pointing somewhere unexpected — cannot be used to
// reach internal services (SSRF). Ported from the pirivision reference
// project. See docs/reference/platform/architecture.md §10.
package nethost

import (
	"fmt"
	"net/http"
)

// AllowList is the set of hostnames a service is permitted to call.
type AllowList map[string]bool

// Guard wraps an http.RoundTripper, rejecting requests to hosts that are
// not present in the allow-list.
func Guard(allow AllowList, next http.RoundTripper) http.RoundTripper {
	if next == nil {
		next = http.DefaultTransport
	}
	return &guardedTransport{allow: allow, next: next}
}

type guardedTransport struct {
	allow AllowList
	next  http.RoundTripper
}

func (g *guardedTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	host := req.URL.Hostname()
	if !g.allow[host] {
		return nil, fmt.Errorf("nethost: host not allow-listed: %s", host)
	}
	return g.next.RoundTrip(req)
}

// Client builds an *http.Client whose transport enforces allow.
func Client(allow AllowList) *http.Client {
	return &http.Client{Transport: Guard(allow, nil)}
}
