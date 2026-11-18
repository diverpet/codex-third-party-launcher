package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

const modelPattern = "(?i)(^|/)(gpt|chatgpt)([-_.0-9][^/]*)?$"

func TestProtectedRequestsNeverReachUpstream(t *testing.T) {
	var forwarded atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		forwarded.Add(1)
		t.Errorf("unexpected upstream request: %s %s", r.Method, r.URL.Path)
	}))
	defer upstream.Close()
	handler, err := makeHandler(settings{upstream.URL + "/v1", "upstream-key", "local-key", modelPattern})
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name string
		path string
		body string
		key  string
		code int
	}{
		{"Luna", "/responses", `{"model":"gpt-6-luna","input":"test"}`, "local-key", 400},
		{"namespaced GPT", "/responses/compact", `{"model":"openai/GPT-6.1-terra"}`, "local-key", 400},
		{"escaped model", "/responses", `{"model":"\u0067pt-6-luna"}`, "local-key", 400},
		{"duplicate model", "/responses", `{"model":"gpt-6-luna","model":"allowed"}`, "local-key", 400},
		{"capitalized field", "/responses", `{"Model":"gpt-6-luna","model":"allowed"}`, "local-key", 400},
		{"missing model", "/responses", `{"input":"test"}`, "local-key", 400},
		{"unknown inference route", "/batches", `{"input_file_id":"file-123"}`, "local-key", 400},
		{"unauthenticated", "/responses", `{"model":"allowed"}`, "wrong", 401},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, test.path, strings.NewReader(test.body))
			request.Header.Set("Authorization", "Bearer "+test.key)
			request.Header.Set("Content-Type", "application/json")
			result := httptest.NewRecorder()
			handler.ServeHTTP(result, request)
			if result.Code != test.code {
				t.Fatalf("got HTTP %d, want %d", result.Code, test.code)
			}
		})
	}
	if got := forwarded.Load(); got != 0 {
		t.Fatalf("forwarded %d blocked requests", got)
	}
}

func TestAllowedModelPreservesGatewayPathAndStreaming(t *testing.T) {
	const input = `{"model":"other-v1","stream":true}`
	const output = "data: {\"type\":\"response.completed\"}\n\n"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.URL.Path != "/custom/v1/responses" || r.Header.Get("Authorization") != "Bearer upstream-key" || string(body) != input {
			t.Error("gateway path, credential or request body changed")
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, output)
		w.(http.Flusher).Flush()
	}))
	defer upstream.Close()
	handler, err := makeHandler(settings{upstream.URL + "/custom/v1", "upstream-key", "local-key", modelPattern})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/responses", strings.NewReader(input))
	request.Header.Set("Authorization", "Bearer local-key")
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || response.Header().Get("Content-Type") != "text/event-stream" ||
		response.Body.String() != output || !response.Flushed {
		t.Fatalf("unexpected stream result: %d %s", response.Code, response.Body)
	}
}
