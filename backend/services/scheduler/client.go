// Package scheduler implements pay-scheduler-service: the sweep that turns
// an expired, never-claimed cheque's permissionless refund from "someone
// could call this" into "someone does" (p2p doc §6.2, §9.B1, D9).
package scheduler

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
)

// ChequeClient calls pay-cheque-service's internal sweep routes — the only
// two endpoints scheduler needs, so this stays a tiny purpose-built client
// rather than a full ports.ChainGateway-style adapter.
type ChequeClient struct {
	baseURL     string
	internalKey string
	hc          *http.Client
}

func NewChequeClient(baseURL, internalKey string, hc *http.Client) *ChequeClient {
	if hc == nil {
		hc = http.DefaultClient
	}
	return &ChequeClient{baseURL: baseURL, internalKey: internalKey, hc: hc}
}

// ExpiredCheque is the subset of pay.cheques the sweep needs.
type ExpiredCheque struct {
	ID              string `json:"id"`
	SenderAddress   string `json:"senderAddress"`
	ReceiverAddress string `json:"receiverAddress"`
	TokenContract   string `json:"tokenContract"`
	AmountRaw       string `json:"amountRaw"`
	Decimals        uint8  `json:"decimals"`
}

func (c *ChequeClient) ExpiredFundedCheques(ctx context.Context) ([]ExpiredCheque, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+"/internal/cheques/expired-funded", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Internal-Api-Key", c.internalKey)
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("scheduler: fetch expired cheques: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("scheduler: fetch expired cheques: status %d", resp.StatusCode)
	}
	var envelope struct {
		Data []struct {
			ID              string `json:"id"`
			SenderAddress   string `json:"senderAddress"`
			ReceiverAddress string `json:"receiverAddress"`
			TokenContract   string `json:"tokenContract"`
			AmountRaw       string `json:"amountRaw"`
			Decimals        uint8  `json:"decimals"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return nil, fmt.Errorf("scheduler: decode expired cheques: %w", err)
	}
	out := make([]ExpiredCheque, len(envelope.Data))
	for i, d := range envelope.Data {
		out[i] = ExpiredCheque(d)
	}
	return out, nil
}

func (c *ChequeClient) MarkRefunded(ctx context.Context, chequeID, txHash string) error {
	body, _ := json.Marshal(map[string]string{"txHash": txHash})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/internal/cheques/"+chequeID+"/mark-refunded", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Internal-Api-Key", c.internalKey)
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("scheduler: mark refunded: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("scheduler: mark refunded: status %d", resp.StatusCode)
	}
	return nil
}
