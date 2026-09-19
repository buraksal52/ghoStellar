package cheque

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestInternalHandler_ExpiredFunded(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateHavuzda)
	stored, _ := repo.GetCheque(context.Background(), c.ID)
	stored.ExpiresAt = time.Now().Add(-time.Minute)
	repo.cheques[c.ID] = stored

	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	h := NewInternalHandler(svc)
	mux := http.NewServeMux()
	RegisterInternalRoutes(mux, h)

	req := httptest.NewRequest("GET", "/internal/cheques/expired-funded", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d, body=%s", rec.Code, rec.Body.String())
	}
	var env struct {
		Data []Cheque `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(env.Data) != 1 || env.Data[0].ID != c.ID {
		t.Fatalf("got %d cheques, want [%s]", len(env.Data), c.ID)
	}
}

func TestInternalHandler_MarkRefunded(t *testing.T) {
	repo := newFakeRepo()
	c := seedCheque(t, repo, StateHavuzda)
	svc := newServiceWithRepo(testConfig(), repo, fundedChain(t, 1))
	h := NewInternalHandler(svc)
	mux := http.NewServeMux()
	RegisterInternalRoutes(mux, h)

	req := httptest.NewRequest("POST", "/internal/cheques/"+c.ID+"/mark-refunded", strings.NewReader(`{"txHash":"refund-1"}`))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d, body=%s", rec.Code, rec.Body.String())
	}
	final, err := repo.GetCheque(req.Context(), c.ID)
	if err != nil {
		t.Fatalf("GetCheque: %v", err)
	}
	if final.State != StateIadeEdildi {
		t.Errorf("state = %v, want IADE_EDILDI", final.State)
	}
}
