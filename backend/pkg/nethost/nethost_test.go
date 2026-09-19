package nethost

import (
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// hostnameOf strips the port from an httptest.Server listener address —
// Guard checks req.URL.Hostname() (no port), so the allow-list entry must
// be the bare host.
func hostnameOf(t *testing.T, addr string) string {
	t.Helper()
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatal(err)
	}
	return host
}

func TestGuard_BlocksDisallowedHost(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	hc := Client(AllowList{"some-other-host.example": true})
	_, err := hc.Get(srv.URL)
	if err == nil {
		t.Fatal("expected the request to be blocked by the allow-list")
	}
}

func TestGuard_AllowsListedHost(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	host := hostnameOf(t, srv.Listener.Addr().String()) // httptest.Server URLs use "127.0.0.1:PORT" as the Host
	hc := Client(AllowList{host: true})
	resp, err := hc.Get(srv.URL)
	if err != nil {
		t.Fatalf("expected the request to be allowed, got %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
}

func TestAddAllowedHost_GrowsAllowList(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	host := hostnameOf(t, srv.Listener.Addr().String())

	hc := Client(AllowList{}) // starts empty
	if _, err := hc.Get(srv.URL); err == nil {
		t.Fatal("expected the request to be blocked before AddAllowedHost")
	}

	AddAllowedHost(hc, host)
	resp, err := hc.Get(srv.URL)
	if err != nil {
		t.Fatalf("expected the request to be allowed after AddAllowedHost, got %v", err)
	}
	resp.Body.Close()
}

func TestAddAllowedHost_NoopOnPlainClient(t *testing.T) {
	hc := &http.Client{} // not built via Client/Guard
	// Must not panic.
	AddAllowedHost(hc, "anything.example")
}

// TestAddAllowedHost_ConcurrentSafe exercises the mutex-guarded slice under
// -race: many goroutines growing the allow-list while others read it via
// RoundTrip must never race.
func TestAddAllowedHost_ConcurrentSafe(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	host := hostnameOf(t, srv.Listener.Addr().String())

	hc := Client(AllowList{host: true})
	var wg sync.WaitGroup
	for range 20 {
		wg.Add(2)
		go func() {
			defer wg.Done()
			AddAllowedHost(hc, host)
		}()
		go func() {
			defer wg.Done()
			resp, err := hc.Get(srv.URL)
			if err == nil {
				resp.Body.Close()
			}
		}()
	}
	wg.Wait()
}
