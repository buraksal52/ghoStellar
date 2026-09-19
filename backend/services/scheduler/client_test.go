package scheduler

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestChequeClient_ExpiredFundedCheques(t *testing.T) {
	var gotKey string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotKey = r.Header.Get("X-Internal-Api-Key")
		if r.URL.Path != "/internal/cheques/expired-funded" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"data":[{"id":"01AA","senderAddress":"GS","receiverAddress":"GR","tokenContract":"CT","amountRaw":"100","decimals":7}]}`))
	}))
	defer srv.Close()

	c := NewChequeClient(srv.URL, "secret-key", nil)
	list, err := c.ExpiredFundedCheques(t.Context())
	if err != nil {
		t.Fatalf("ExpiredFundedCheques: %v", err)
	}
	if gotKey != "secret-key" {
		t.Errorf("X-Internal-Api-Key = %q, want secret-key", gotKey)
	}
	if len(list) != 1 || list[0].ID != "01AA" || list[0].AmountRaw != "100" {
		t.Fatalf("unexpected list: %+v", list)
	}
}

func TestChequeClient_ExpiredFundedCheques_UpstreamErrorPropagated(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	c := NewChequeClient(srv.URL, "secret-key", nil)
	if _, err := c.ExpiredFundedCheques(t.Context()); err == nil {
		t.Fatal("expected an error for a 500 upstream response")
	}
}

func TestChequeClient_MarkRefunded(t *testing.T) {
	var gotPath, gotKey, gotTxHash string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotKey = r.Header.Get("X-Internal-Api-Key")
		var body struct {
			TxHash string `json:"txHash"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		gotTxHash = body.TxHash
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := NewChequeClient(srv.URL, "secret-key", nil)
	if err := c.MarkRefunded(t.Context(), "01AA", "hash-123"); err != nil {
		t.Fatalf("MarkRefunded: %v", err)
	}
	if gotPath != "/internal/cheques/01AA/mark-refunded" {
		t.Errorf("path = %q", gotPath)
	}
	if gotKey != "secret-key" {
		t.Errorf("X-Internal-Api-Key = %q", gotKey)
	}
	if gotTxHash != "hash-123" {
		t.Errorf("txHash = %q, want hash-123", gotTxHash)
	}
}

func TestChequeClient_MarkRefunded_UpstreamErrorPropagated(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
	}))
	defer srv.Close()

	c := NewChequeClient(srv.URL, "secret-key", nil)
	if err := c.MarkRefunded(t.Context(), "01AA", "hash-123"); err == nil {
		t.Fatal("expected an error for a 400 upstream response")
	}
}
