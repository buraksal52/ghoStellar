package httpx

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestWriteData_EnvelopeShape(t *testing.T) {
	rec := httptest.NewRecorder()
	WriteData(rec, http.StatusCreated, map[string]string{"x": "y"})

	if rec.Code != http.StatusCreated {
		t.Errorf("status = %d, want 201", rec.Code)
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if _, ok := body["data"]; !ok {
		t.Error("expected a top-level \"data\" key")
	}
	if _, ok := body["error"]; ok {
		t.Error("success envelope must not carry an \"error\" key")
	}
}

func TestWriteError_EnvelopeShape(t *testing.T) {
	rec := httptest.NewRecorder()
	WriteError(rec, http.StatusBadRequest, "domain.specific_error", "message", map[string]string{"field": "x"})

	var body ErrorEnvelope
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Error.Code != "domain.specific_error" {
		t.Errorf("code = %q", body.Error.Code)
	}
	if body.Error.Message != "message" {
		t.Errorf("message = %q", body.Error.Message)
	}
}

func TestHealthHandler_ReportsDBReady(t *testing.T) {
	for _, ready := range []bool{true, false} {
		h := HealthHandler(func() bool { return ready })
		rec := httptest.NewRecorder()
		h(rec, httptest.NewRequest("GET", "/health", nil))

		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
		var body struct {
			Data HealthPayload `json:"data"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if body.Data.DBReady != ready {
			t.Errorf("db_ready = %v, want %v", body.Data.DBReady, ready)
		}
		if body.Data.Status != "ok" {
			t.Errorf("status field = %q, want ok", body.Data.Status)
		}
	}
}

func TestWithRequestID_MintsWhenAbsent(t *testing.T) {
	var gotID string
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotID = RequestID(r.Context())
	})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/x", nil)
	WithRequestID(next).ServeHTTP(rec, req)

	if gotID == "" {
		t.Fatal("expected a minted request id in context")
	}
	if rec.Header().Get(RequestIDHeader) != gotID {
		t.Errorf("response header = %q, want %q", rec.Header().Get(RequestIDHeader), gotID)
	}
}

func TestWithRequestID_PropagatesIncoming(t *testing.T) {
	var gotID string
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotID = RequestID(r.Context())
	})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/x", nil)
	req.Header.Set(RequestIDHeader, "incoming-id")
	WithRequestID(next).ServeHTTP(rec, req)

	if gotID != "incoming-id" {
		t.Errorf("got %q, want incoming-id", gotID)
	}
}

func TestRequestID_AbsentReturnsEmpty(t *testing.T) {
	if got := RequestID(context.Background()); got != "" {
		t.Errorf("got %q, want empty string", got)
	}
}

// ---- Recover ----------------------------------------------------------------

func TestRecover_PanicMapsTo500(t *testing.T) {
	panicky := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		panic("boom")
	})
	rec := httptest.NewRecorder()
	Recover(discardLogger(), panicky).ServeHTTP(rec, httptest.NewRequest("GET", "/x", nil))

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
	var body ErrorEnvelope
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Error.Code != "internal.panic" {
		t.Errorf("code = %q", body.Error.Code)
	}
}

func TestRecover_NextRequestStillWorks(t *testing.T) {
	calls := 0
	h := Recover(discardLogger(), http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			panic("first request panics")
		}
		WriteData(w, http.StatusOK, nil)
	}))

	rec1 := httptest.NewRecorder()
	h.ServeHTTP(rec1, httptest.NewRequest("GET", "/x", nil))
	if rec1.Code != http.StatusInternalServerError {
		t.Fatalf("first request status = %d, want 500", rec1.Code)
	}

	rec2 := httptest.NewRecorder()
	h.ServeHTTP(rec2, httptest.NewRequest("GET", "/x", nil))
	if rec2.Code != http.StatusOK {
		t.Fatalf("second request status = %d, want 200 (process must survive the first panic)", rec2.Code)
	}
}

func TestRecover_NoPanicPassesThrough(t *testing.T) {
	h := Recover(discardLogger(), http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		WriteData(w, http.StatusTeapot, nil)
	}))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/x", nil))
	if rec.Code != http.StatusTeapot {
		t.Fatalf("status = %d, want 418 (unaffected by Recover)", rec.Code)
	}
}

// ---- MaxBody -----------------------------------------------------------------

func TestMaxBody_RejectsOversizedBody(t *testing.T) {
	h := MaxBody(10, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, err := io.ReadAll(r.Body)
		if err != nil {
			WriteError(w, http.StatusBadRequest, "test.too_large", err.Error(), nil)
			return
		}
		WriteData(w, http.StatusOK, nil)
	}))

	rec := httptest.NewRecorder()
	body := bytes.Repeat([]byte("a"), 100)
	req := httptest.NewRequest("POST", "/x", bytes.NewReader(body))
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 (body exceeds MaxBody cap)", rec.Code)
	}
}

func TestMaxBody_AllowsBodyUnderCap(t *testing.T) {
	h := MaxBody(1<<20, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		WriteData(w, http.StatusOK, nil)
	}))
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/x", bytes.NewReader([]byte("small body")))
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
}

// ---- ListenAndServe -----------------------------------------------------------

// TestListenAndServe_GracefulShutdown starts a real listener on an
// ephemeral port, confirms it serves traffic, then cancels its context and
// asserts ListenAndServe returns cleanly (nil) within the shutdown grace
// period instead of hanging or erroring.
func TestListenAndServe_GracefulShutdown(t *testing.T) {
	addr := freeAddr(t)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- ListenAndServe(ctx, addr, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			WriteData(w, http.StatusOK, nil)
		}), discardLogger(), ServeOptions{ShutdownGrace: 2 * time.Second})
	}()

	waitForServer(t, addr)

	resp, err := http.Get("http://" + addr + "/x")
	if err != nil {
		t.Fatalf("GET during serve: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("ListenAndServe returned %v, want nil after graceful shutdown", err)
	}
}

// freeAddr reserves an ephemeral loopback port and returns its address as
// "host:port", closing the probe listener immediately so ListenAndServe can
// bind it itself. There is an inherent (tiny, practically never observed in
// CI) race between the close and the real bind; accepted for a test helper.
func freeAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	return addr
}

func waitForServer(t *testing.T, addr string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 50*time.Millisecond)
		if err == nil {
			conn.Close()
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("server at %s did not start in time", addr)
}
