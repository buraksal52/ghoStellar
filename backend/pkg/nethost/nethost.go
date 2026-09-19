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
	"slices"
	"sync"
)

// AllowList is the set of hostnames a service is permitted to call.
type AllowList map[string]bool

// Guard wraps an http.RoundTripper, rejecting requests to hosts that are
// not present in the allow-list.
func Guard(allow AllowList, next http.RoundTripper) http.RoundTripper {
	if next == nil {
		next = http.DefaultTransport
	}
	g := &guardedTransport{next: next}
	for host, ok := range allow {
		if ok {
			g.allow = append(g.allow, host)
		}
	}
	return g
}

// guardedTransport's allow set is read on every request and can be grown at
// runtime (AddAllowedHost) by a service that only learns some of its
// legitimate destinations after an initial call (e.g. pay-anchor-service
// resolving TRANSFER_SERVER/KYC_SERVER/ANCHOR_QUOTE_SERVER hosts from an
// anchor's own SEP-1 toml, which may differ from the toml's own host). A
// plain map would race under concurrent requests; a mutex-guarded slice
// keeps additions and lookups safe without requiring the whole allow-list
// to be known upfront.
type guardedTransport struct {
	mu    sync.RWMutex
	allow []string
	next  http.RoundTripper
}

func (g *guardedTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	host := req.URL.Hostname()
	g.mu.RLock()
	ok := slices.Contains(g.allow, host)
	g.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("nethost: host not allow-listed: %s", host)
	}
	return g.next.RoundTrip(req)
}

func (g *guardedTransport) addHost(host string) {
	if host == "" {
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if !slices.Contains(g.allow, host) {
		g.allow = append(g.allow, host)
	}
}

// Client builds an *http.Client whose transport enforces allow.
func Client(allow AllowList) *http.Client {
	return &http.Client{Transport: Guard(allow, nil)}
}

// AddAllowedHost grows hc's allow-list to also permit host, if hc's
// Transport was built by Client/Guard. It is a no-op (never panics) on any
// other *http.Client, so callers can use it defensively. Safe to call
// concurrently with in-flight requests through hc.
func AddAllowedHost(hc *http.Client, host string) {
	if g, ok := hc.Transport.(*guardedTransport); ok {
		g.addHost(host)
	}
}
