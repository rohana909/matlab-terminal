// Copyright 2026 The MathWorks, Inc.

package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// ECClient implements MATLABClient by talking to the MATLAB Embedded Connector
// over HTTPS on localhost.
type ECClient struct {
	baseURL  string
	mwapikey string
	client   *http.Client
}

// NewECClient creates a client connected to the EC at the given port.
// TLS verification is skipped because the EC uses a self-signed certificate
// and we are connecting to localhost (same user, same machine).
func NewECClient(port int, mwapikey string) *ECClient {
	return &ECClient{
		baseURL:  fmt.Sprintf("https://127.0.0.1:%d", port),
		mwapikey: mwapikey,
		client: &http.Client{
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
			},
		},
	}
}

// connectorPayload is the JSON structure the EC expects.
type connectorPayload struct {
	UUID         string          `json:"uuid"`
	Messages     json.RawMessage `json:"messages"`
	ComputeToken computeToken    `json:"computeToken"`
}

type computeToken struct {
	ComputeSessionID string `json:"computeSessionId"`
}

// evalMessage is a single Eval request inside a ConnectorPayload.
type evalMessage struct {
	MCode string `json:"mcode"`
	UUID  string `json:"uuid"`
}

// fevalMessage is a single FEval request inside a ConnectorPayload.
type fevalMessage struct {
	Function string `json:"function"`
	Args     []any  `json:"args"`
	Nargout  int    `json:"nargout"`
	UUID     string `json:"uuid"`
}

// Eval sends MATLAB code to the EC and returns the console output.
func (ec *ECClient) Eval(ctx context.Context, code string) (string, error) {
	msg := evalMessage{MCode: code, UUID: "mts-eval"}
	msgs, err := json.Marshal(map[string][]evalMessage{"Eval": {msg}})
	if err != nil {
		return "", fmt.Errorf("marshal eval: %w", err)
	}

	body, err := ec.post(ctx, "/messageservice/json/secure", msgs)
	if err != nil {
		return "", err
	}

	// Parse the EC response to extract the console output.
	var resp struct {
		Messages struct {
			EvalResponse []struct {
				IsError     bool   `json:"isError"`
				ResponseStr string `json:"responseStr"`
			} `json:"EvalResponse"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return string(body), nil
	}
	if len(resp.Messages.EvalResponse) > 0 {
		r := resp.Messages.EvalResponse[0]
		if r.IsError {
			return "", fmt.Errorf("MATLAB error: %s", r.ResponseStr)
		}
		return r.ResponseStr, nil
	}
	return string(body), nil
}

// FEval calls a MATLAB function via the EC and returns the results.
func (ec *ECClient) FEval(ctx context.Context, fn string, args []any, nargout int) ([]any, error) {
	if args == nil {
		args = []any{}
	}
	msg := fevalMessage{Function: fn, Args: args, Nargout: nargout, UUID: "mts-feval"}
	msgs, err := json.Marshal(map[string][]fevalMessage{"FEval": {msg}})
	if err != nil {
		return nil, fmt.Errorf("marshal feval: %w", err)
	}

	body, err := ec.post(ctx, "/messageservice/json/secure", msgs)
	if err != nil {
		return nil, err
	}

	// Parse the EC response. FEval returns results in a JSON structure.
	var resp struct {
		Messages struct {
			FEvalResponse []struct {
				IsError bool   `json:"isError"`
				Error   string `json:"error"`
				Results []any  `json:"results"`
			} `json:"FEvalResponse"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		// If structured parsing fails, return the raw body as a single result.
		return []any{string(body)}, nil
	}

	if len(resp.Messages.FEvalResponse) > 0 {
		r := resp.Messages.FEvalResponse[0]
		if r.IsError {
			return nil, fmt.Errorf("MATLAB error: %s", r.Error)
		}
		return r.Results, nil
	}

	return []any{string(body)}, nil
}

// Ping checks if MATLAB is alive by sending a state query to the EC.
func (ec *ECClient) Ping(ctx context.Context) bool {
	msgs, _ := json.Marshal(map[string][]map[string]string{
		"Ping": {{"uuid": "mts-ping"}},
	})
	_, err := ec.post(ctx, "/messageservice/json/state", msgs)
	return err == nil
}

// post sends a ConnectorPayload to the given EC endpoint.
func (ec *ECClient) post(ctx context.Context, path string, messages json.RawMessage) ([]byte, error) {
	payload := connectorPayload{
		UUID:         "mts",
		Messages:     messages,
		ComputeToken: computeToken{ComputeSessionID: "mts"},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("marshal payload: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", ec.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("mwapikey", ec.mwapikey)

	resp, err := ec.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("EC request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read EC response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("EC returned %d: %s", resp.StatusCode, string(respBody))
	}

	return respBody, nil
}
