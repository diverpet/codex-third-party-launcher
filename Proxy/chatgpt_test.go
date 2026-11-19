package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestChatGPTAuthorizedRoutesKeepCredentialsSeparate(t *testing.T) {
	var gatewayCalls, chatGPTCalls atomic.Int32
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gatewayCalls.Add(1)
		if got := r.Header.Get("Authorization"); got != "Bearer gateway-key" {
			t.Errorf("gateway received wrong credential")
		}
		if data, _ := io.ReadAll(r.Body); !strings.Contains(string(data), `"model":"deepseek-fixture"`) {
			t.Error("gateway model unexpectedly changed")
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer gateway.Close()
	official := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		chatGPTCalls.Add(1)
		if r.URL.Path != "/v1/responses" || r.Header.Get("Authorization") != "Bearer account-token" ||
			r.Header.Get("X-Api-Key") != "" || r.Header.Get("Cookie") != "" {
			t.Error("ChatGPT request used the wrong path or credentials")
		}
		var payload map[string]json.RawMessage
		if json.NewDecoder(r.Body).Decode(&payload) != nil || string(payload["model"]) != `"gpt-6.1-sol"` ||
			string(payload["store"]) != "false" || string(payload["stream"]) != "true" ||
			len(payload["metadata"]) != 0 || !strings.HasPrefix(string(payload["input"]), "[") {
			t.Error("ChatGPT request was not adapted to the documented Responses contract")
		}
		var tools []map[string]any
		if json.Unmarshal(payload["tools"], &tools) != nil || len(tools) != 1 ||
			tools[0]["type"] != "web_search" || tools[0]["external_web_access"] != false {
			t.Error("ChatGPT did not receive the selected Web Search mode")
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: {\"type\":\"response.completed\"}\n\n")
	}))
	defer official.Close()

	handler, err := makeHandler(settings{BaseURL: gateway.URL + "/v1", UpstreamKey: "gateway-key",
		LocalKey: "local-key", ModelPattern: modelPattern}, &chatGPTRoute{
		baseURL: official.URL + "/v1",
		aliases: map[string]chatGPTModelRoute{"chatgpt/gpt-6.1-sol": {slug: "gpt-6.1-sol"}},
		access:  func(context.Context) (string, error) { return "account-token", nil },
	})
	if err != nil {
		t.Fatal(err)
	}

	send := func(path, body string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
		request.Header.Set("Authorization", "Bearer local-key")
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("X-Api-Key", "untrusted-header")
		request.Header.Set("Cookie", "untrusted-cookie")
		result := httptest.NewRecorder()
		handler.ServeHTTP(result, request)
		return result
	}
	for _, model := range []string{"gpt-6-luna", "chatgpt/gpt-6-luna"} {
		if r := send("/responses", `{"model":"`+model+`","input":"test"}`); r.Code != http.StatusBadRequest {
			t.Errorf("%s unexpectedly returned HTTP %d", model, r.Code)
		}
	}
	if r := send("/responses/compact", `{"model":"chatgpt/gpt-6.1-sol","input":"test"}`); r.Code != http.StatusBadRequest {
		t.Fatal("unsupported ChatGPT endpoint should be rejected locally")
	}
	if r := send("/responses", `{"model":"deepseek-fixture","input":"test"}`); r.Code != http.StatusOK {
		t.Fatal("the gateway model should still work")
	}
	if r := send("/responses", `{"model":"chatgpt/gpt-6.1-sol","input":"test","metadata":{},
		"tools":[{"type":"web_search","external_web_access":false},{"type":"file_search"}]}`); r.Code != http.StatusOK ||
		!strings.Contains(r.Body.String(), "response.completed") {
		t.Fatal("the ChatGPT model should stream to completion")
	}
	if gatewayCalls.Load() != 1 || chatGPTCalls.Load() != 1 {
		t.Fatalf("unexpected calls across providers: gateway=%d ChatGPT=%d", gatewayCalls.Load(), chatGPTCalls.Load())
	}
}

func TestChatGPTSpeedVariantsInCatalogAndResponses(t *testing.T) {
	var models []map[string]json.RawMessage
	fixture := `[
		{"slug":"gpt-fixture","display_name":"GPT Fixture","visibility":"list","context_window":272000,
		 "service_tiers":[{"id":"ultrafast"},{"id":"priority"},{"id":"fast"}],"default_service_tier":"fast"},
		{"slug":"legacy","visibility":"list","additional_speed_tiers":["fast"]},
		{"slug":"standard-only","visibility":"list","service_tiers":[],"additional_speed_tiers":["fast"]},
		{"slug":"hidden","visibility":"hide","service_tiers":[{"id":"priority"}]}
	]`
	if err := json.Unmarshal([]byte(fixture), &models); err != nil {
		t.Fatal(err)
	}
	catalog, aliases, err := planCatalog(models)
	if err != nil {
		t.Fatal(err)
	}
	var visible struct {
		Models []struct {
			Slug          string `json:"slug"`
			DisplayName   string `json:"display_name"`
			ContextWindow int    `json:"context_window"`
		} `json:"models"`
	}
	if err := json.Unmarshal(catalog, &visible); err != nil {
		t.Fatal(err)
	}
	want := []struct{ alias, label, model, tier string }{
		{"chatgpt/gpt-fixture", "GPT Fixture · ChatGPT · 标准", "gpt-fixture", "default"},
		{"chatgpt/gpt-fixture/fast", "GPT Fixture · ChatGPT · 快速", "gpt-fixture", "priority"},
		{"chatgpt/gpt-fixture/ultrafast", "GPT Fixture · ChatGPT · 极速", "gpt-fixture", "ultrafast"},
		{"chatgpt/legacy", "legacy · ChatGPT · 标准", "legacy", "default"},
		{"chatgpt/legacy/fast", "legacy · ChatGPT · 快速", "legacy", "priority"},
		{"chatgpt/standard-only", "standard-only · ChatGPT", "standard-only", "auto"},
	}
	if len(visible.Models) != len(want) || len(aliases) != len(want) {
		t.Fatalf("unexpected model choices: %v", visible.Models)
	}
	if strings.Contains(string(catalog), `"default_service_tier"`) {
		t.Fatal("the default tier must be selected by alias rather than inherited from the model")
	}
	for i, choice := range want {
		entry := visible.Models[i]
		if entry.Slug != choice.alias || entry.DisplayName != choice.label ||
			(choice.model == "gpt-fixture" && entry.ContextWindow != 272000) {
			t.Errorf("unexpected catalog entry: %+v", entry)
		}
	}

	type wireRequest struct {
		Model string `json:"model"`
		Tier  string `json:"service_tier"`
	}
	requests := make(chan wireRequest, len(want))
	official := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		var payload wireRequest
		if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
			t.Error(err)
		}
		requests <- payload
		w.WriteHeader(http.StatusOK)
	}))
	defer official.Close()
	handler, err := makeHandler(settings{BaseURL: "http://127.0.0.1:1/v1", UpstreamKey: "gateway-key",
		LocalKey: "local-key", ModelPattern: modelPattern}, &chatGPTRoute{
		baseURL: official.URL + "/v1",
		aliases: aliases,
		access:  func(context.Context) (string, error) { return "account-token", nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	send := func(model string) int {
		request := httptest.NewRequest(http.MethodPost, "/responses", strings.NewReader(
			`{"model":"`+model+`","input":"test","service_tier":"auto"}`))
		request.Header.Set("Authorization", "Bearer local-key")
		request.Header.Set("Content-Type", "application/json")
		result := httptest.NewRecorder()
		handler.ServeHTTP(result, request)
		return result.Code
	}
	for _, choice := range want {
		if status := send(choice.alias); status != http.StatusOK {
			t.Fatalf("%s returned HTTP %d", choice.alias, status)
		}
		select {
		case got := <-requests:
			if got != (wireRequest{Model: choice.model, Tier: choice.tier}) {
				t.Errorf("%s sent %+v upstream", choice.alias, got)
			}
		default:
			t.Fatalf("%s did not reach ChatGPT", choice.alias)
		}
	}
	for _, unavailable := range []string{"chatgpt/legacy/ultrafast", "chatgpt/standard-only/fast", "chatgpt/hidden/fast"} {
		if status := send(unavailable); status != http.StatusBadRequest {
			t.Errorf("%s was not rejected locally, got HTTP %d", unavailable, status)
		}
	}
}

func TestChatGPTAuthorizationValidatesStatePKCEAndIdentity(t *testing.T) {
	signingKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	previous := chatGPTHTTP
	defer func() { chatGPTHTTP = previous }()
	encoding := base64.RawURLEncoding
	const issued = "oaiapp_fixture"
	var authorization url.Values
	chatGPTHTTP = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		var payload any
		switch r.URL.Path {
		case "/api/accounts/oauth/token":
			if err := r.ParseForm(); err != nil {
				return nil, err
			}
			if r.Form.Get("grant_type") == "refresh_token" {
				if r.Form.Get("refresh_token") != "fixture-refresh" || r.Form.Get("client_id") != issued {
					t.Error("refresh used the wrong registration or credential")
				}
				payload = planToken{AccessToken: "rotated-access", RefreshToken: "rotated-refresh",
					TokenType: "Bearer", Scope: chatGPTPlanScope, ExpiresIn: 3600}
				break
			}
			digest := sha256.Sum256([]byte(r.Form.Get("code_verifier")))
			if r.Form.Get("code") != "fixture-code" || r.Form.Get("client_id") != issued ||
				r.Form.Get("redirect_uri") != authorization.Get("redirect_uri") ||
				encoding.EncodeToString(digest[:]) != authorization.Get("code_challenge") {
				t.Error("the exchange did not preserve the authorization attempt")
			}
			idClaims, _ := json.Marshal(map[string]any{"iss": chatGPTIssuer, "aud": issued,
				"sub": "fixture-subject", "email": "fixture@example.test", "nonce": authorization.Get("nonce"),
				"exp": time.Now().Add(time.Hour).Unix(), "iat": time.Now().Unix()})
			signed := encoding.EncodeToString([]byte(`{"alg":"RS256","kid":"fixture"}`)) + "." + encoding.EncodeToString(idClaims)
			sum := sha256.Sum256([]byte(signed))
			proof, err := rsa.SignPKCS1v15(rand.Reader, signingKey, crypto.SHA256, sum[:])
			if err != nil {
				return nil, err
			}
			payload = planToken{"fixture-access", "fixture-refresh", signed + "." + encoding.EncodeToString(proof), "Bearer", chatGPTPlanScope, 3600}
		case "/.well-known/jwks.json":
			payload = map[string]any{"keys": []map[string]string{{"kty": "RSA", "kid": "fixture", "alg": "RS256",
				"n": encoding.EncodeToString(signingKey.N.Bytes()), "e": "AQAB"}}}
		default:
			t.Errorf("unexpected auth request path %s", r.URL.Path)
		}
		body, _ := json.Marshal(payload)
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(body))), Header: http.Header{"Content-Type": {"application/json"}}}, nil
	}), Timeout: 5 * time.Second}
	folder := filepath.Join(t.TempDir(), "plan")
	plan, lock, first, err := connectChatGPT(context.Background(), folder, func(event proxyEvent) error {
		login, err := url.Parse(event.AuthorizeURL)
		if err != nil {
			return err
		}
		authorization = login.Query()
		if login.Host != "auth.openai.com" || authorization.Get("client_id") != "dynamic_agent_client" ||
			authorization.Get("code_challenge_method") != "S256" || authorization.Get("ext_agent_host_id") == "" {
			t.Error("invalid initial authorization parameters")
		}
		callback := authorization.Get("redirect_uri")
		client := &http.Client{Timeout: 3 * time.Second}
		for _, entry := range []struct {
			state  string
			status int
		}{
			{"incorrect-state", http.StatusBadRequest}, {authorization.Get("state"), http.StatusOK},
		} {
			response, err := client.Get(callback + "?" + url.Values{"code": {"fixture-code"}, "client_id": {issued}, "state": {entry.state}}.Encode())
			if err != nil {
				return err
			}
			response.Body.Close()
			if response.StatusCode != entry.status {
				t.Errorf("callback got HTTP %d", response.StatusCode)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	lock.Close()
	if !first || plan.record.Subject != "fixture-subject" || plan.record.ClientID != issued {
		t.Fatal("wrong account was persisted")
	}
	info, err := os.Stat(plan.path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("account storage is not private")
	}
	second, lock, first, err := connectChatGPT(context.Background(), folder, func(proxyEvent) error {
		t.Error("saved account unexpectedly needs another browser authorization")
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if first || second.record.HostID != plan.record.HostID {
		t.Fatal("saved connection was not reused")
	}
	second.record.Expiry = time.Now().Add(-time.Minute)
	if err := second.save(second.record); err != nil {
		t.Fatal(err)
	}
	lock.Close()
	refreshed, lock, _, err := connectChatGPT(context.Background(), folder, func(proxyEvent) error {
		t.Error("a valid refresh token unexpectedly needed browser authorization")
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if refreshed.record.Token.RefreshToken != "rotated-refresh" || refreshed.record.Subject != plan.record.Subject {
		t.Fatal("refresh did not keep the registration and rotate the tokens")
	}
}
