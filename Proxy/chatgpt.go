package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"maps"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

const (
	chatGPTIssuer    = "https://auth.openai.com"
	chatGPTAPI       = "https://api.openai.com/v1"
	chatGPTPrefix    = "chatgpt/"
	chatGPTPlanScope = "chatgpt.tokens.use.direct"
)

var errChatGPTSignInRequired = errors.New("chatgpt_sign_in_required")
var officialSlug = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]*$`)
var chatGPTHTTP = &http.Client{
	Timeout:       20 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

type planToken struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	IDToken      string `json:"id_token"`
	TokenType    string `json:"token_type"`
	Scope        string `json:"scope"`
	ExpiresIn    int64  `json:"expires_in"`
}

type planRecord struct {
	HostID   string    `json:"host_id"`
	ClientID string    `json:"client_id,omitempty"`
	Subject  string    `json:"subject,omitempty"`
	Email    string    `json:"email,omitempty"`
	Expiry   time.Time `json:"expiry"`
	Token    planToken `json:"token"`
}

type chatGPTPlan struct {
	mu       sync.Mutex
	path     string
	record   planRecord
	newGrant bool
}

type proxyEvent struct {
	AuthorizeURL string `json:"authorizeURL,omitempty"`
	BaseURL      string `json:"baseURL,omitempty"`
	Catalog      []byte `json:"catalog,omitempty"`
	Account      string `json:"account,omitempty"`
	NewGrant     bool   `json:"newGrant,omitempty"`
	Error        string `json:"error,omitempty"`
}

func connectChatGPT(ctx context.Context, directory string, send func(proxyEvent) error) (*chatGPTPlan, *os.File, bool, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, nil, false, err
	}
	stat, err := os.Lstat(directory)
	if err != nil || !stat.IsDir() || stat.Mode().Perm()&0077 != 0 {
		return nil, nil, false, errors.New("unsafe ChatGPT account directory")
	}
	fd, err := syscall.Open(filepath.Join(directory, ".lock"), syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, nil, false, err
	}
	lock := os.NewFile(uintptr(fd), "ChatGPT account lock")
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, nil, false, errors.New("chatgpt_account_in_use")
	}
	plan := &chatGPTPlan{path: filepath.Join(directory, "account.json")}
	if err := plan.prepare(ctx, send); err != nil {
		lock.Close()
		return nil, nil, false, err
	}
	return plan, lock, plan.newGrant, nil
}

func (p *chatGPTPlan) prepare(ctx context.Context, send func(proxyEvent) error) error {
	info, err := os.Lstat(p.path)
	if err == nil {
		if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 256<<10 {
			return errors.New("unsafe ChatGPT account record")
		}
		data, err := os.ReadFile(p.path)
		if err != nil {
			return err
		}
		if err := json.Unmarshal(data, &p.record); err != nil || p.record.HostID == "" {
			return errors.New("invalid ChatGPT account record")
		}
		_, err = p.accessToken(ctx)
		if !errors.Is(err, errChatGPTSignInRequired) {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	} else {
		// A UUIDv4 is a stable, opaque installation identifier.
		id := make([]byte, 16)
		rand.Read(id)
		id[6] = (id[6] & 0x0f) | 0x40
		id[8] = (id[8] & 0x3f) | 0x80
		p.record.HostID = fmt.Sprintf("urn:uuid:%x-%x-%x-%x-%x", id[:4], id[4:6], id[6:8], id[8:10], id[10:])
		if err := p.save(p.record); err != nil {
			return err
		}
	}
	p.newGrant = p.record.ClientID == ""
	return p.authorize(ctx, send)
}

func randomURLValue() string {
	data := make([]byte, 32)
	rand.Read(data)
	return base64.RawURLEncoding.EncodeToString(data)
}

func (p *chatGPTPlan) authorize(ctx context.Context, send func(proxyEvent) error) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer listener.Close()
	redirect := "http://" + listener.Addr().String() + "/auth/callback"
	state, nonce, verifier := randomURLValue(), randomURLValue(), randomURLValue()
	challenge := sha256.Sum256([]byte(verifier))
	clientID := p.record.ClientID
	query := url.Values{
		"client_id": {clientID}, "ext_agent_host_id": {p.record.HostID}, "response_type": {"code"},
		"redirect_uri": {redirect}, "scope": {"openid profile email offline_access resource.invoke " + chatGPTPlanScope},
		"resource": {chatGPTAPI}, "state": {state}, "nonce": {nonce}, "code_challenge_method": {"S256"},
		"code_challenge": {base64.RawURLEncoding.EncodeToString(challenge[:])},
	}
	if clientID == "" {
		query.Set("client_id", "dynamic_agent_client")
		query.Set("agent_name_hint", "Codex Third Party Launcher")
	}
	received := make(chan url.Values, 1)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /auth/callback", func(w http.ResponseWriter, r *http.Request) {
		values := r.URL.Query()
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		if subtle.ConstantTimeCompare([]byte(values.Get("state")), []byte(state)) != 1 {
			http.Error(w, "Invalid authorization request.", http.StatusBadRequest)
			return
		}
		select {
		case received <- values:
			io.WriteString(w, "Return to Codex Third Party Launcher to continue.")
		default:
			http.Error(w, "Authorization was already received.", http.StatusConflict)
		}
	})
	callback := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second, ErrorLog: log.New(io.Discard, "", 0)}
	go callback.Serve(listener)
	defer callback.Close()
	if err := send(proxyEvent{AuthorizeURL: chatGPTIssuer + "/api/accounts/authorize?" + query.Encode()}); err != nil {
		return err
	}
	var values url.Values
	select {
	case values = <-received:
	case <-ctx.Done():
		return ctx.Err()
	}
	if values.Get("error") != "" || values.Get("code") == "" {
		return errors.New("chatgpt_authorization_declined")
	}
	issued := values.Get("client_id")
	if clientID == "" {
		clientID = issued
	} else if issued != "" && issued != clientID {
		return errors.New("ChatGPT OAuth client mismatch")
	}
	if clientID == "" || clientID == "dynamic_agent_client" {
		return errors.New("ChatGPT did not issue a client")
	}

	token, err := fetchPlanToken(ctx, url.Values{
		"grant_type": {"authorization_code"}, "client_id": {clientID}, "resource": {chatGPTAPI},
		"code": {values.Get("code")}, "code_verifier": {verifier}, "redirect_uri": {redirect},
	})
	if err != nil {
		return err
	}
	verifierContext := oidc.ClientContext(ctx, chatGPTHTTP)
	keys := oidc.NewRemoteKeySet(verifierContext, chatGPTIssuer+"/.well-known/jwks.json")
	identity, err := oidc.NewVerifier(chatGPTIssuer, keys, &oidc.Config{ClientID: clientID, SupportedSigningAlgs: []string{oidc.RS256}}).Verify(verifierContext, token.IDToken)
	if err != nil || identity.Nonce != nonce || identity.Subject == "" || (p.record.Subject != "" && identity.Subject != p.record.Subject) {
		return errors.New("ChatGPT identity validation failed")
	}
	var claims struct {
		Email string `json:"email"`
	}
	if err := identity.Claims(&claims); err != nil {
		return err
	}
	next := planRecord{HostID: p.record.HostID, ClientID: clientID, Subject: identity.Subject, Email: claims.Email,
		Expiry: time.Now().Add(time.Duration(token.ExpiresIn) * time.Second), Token: token}
	if err := p.save(next); err != nil {
		return err
	}
	p.record = next
	return nil
}

func fetchPlanToken(ctx context.Context, form url.Values) (planToken, error) {
	var token planToken
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, chatGPTIssuer+"/api/accounts/oauth/token", strings.NewReader(form.Encode()))
	if err != nil {
		return token, err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := chatGPTHTTP.Do(request)
	if err != nil {
		return token, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		var reason struct {
			Error string `json:"error"`
		}
		json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&reason)
		if reason.Error == "invalid_grant" {
			return token, errChatGPTSignInRequired
		}
		return token, errors.New("chatgpt_token_exchange_failed")
	}
	err = json.NewDecoder(io.LimitReader(response.Body, 256<<10)).Decode(&token)
	if err != nil || token.AccessToken == "" || token.RefreshToken == "" || token.ExpiresIn <= 0 ||
		token.ExpiresIn > 86400 || !strings.EqualFold(token.TokenType, "Bearer") || !hasPlanScope(token.Scope) {
		return token, errors.New("chatgpt_plan_not_enabled")
	}
	return token, nil
}

func hasPlanScope(scopes string) bool {
	for _, scope := range strings.Fields(scopes) {
		if scope == chatGPTPlanScope {
			return true
		}
	}
	return false
}

func (p *chatGPTPlan) accessToken(ctx context.Context) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	current := p.record
	if current.Subject == "" || current.ClientID == "" || current.Token.RefreshToken == "" || !hasPlanScope(current.Token.Scope) {
		return "", errChatGPTSignInRequired
	}
	if current.Token.AccessToken != "" && time.Now().Before(current.Expiry.Add(-30*time.Second)) {
		return current.Token.AccessToken, nil
	}
	token, err := fetchPlanToken(ctx, url.Values{"grant_type": {"refresh_token"}, "refresh_token": {current.Token.RefreshToken},
		"client_id": {current.ClientID}, "resource": {chatGPTAPI}})
	if err != nil {
		return "", err
	}
	// Keep the ID token verified during authorization as the reauthorization hint.
	token.IDToken = current.Token.IDToken
	current.Token = token
	current.Expiry = time.Now().Add(time.Duration(token.ExpiresIn) * time.Second)
	if err := p.save(current); err != nil {
		return "", err
	}
	p.record = current
	return token.AccessToken, nil
}

func (p *chatGPTPlan) save(state planRecord) error {
	file, err := os.CreateTemp(filepath.Dir(p.path), ".account-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	err = json.NewEncoder(file).Encode(state)
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(file.Name(), p.path)
}

func (p *chatGPTPlan) models(ctx context.Context) ([]byte, map[string]chatGPTModelRoute, error) {
	token, err := p.accessToken(ctx)
	if err != nil {
		return nil, nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, chatGPTAPI+"/models", nil)
	if err != nil {
		return nil, nil, err
	}
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := chatGPTHTTP.Do(request)
	if err != nil {
		return nil, nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, nil, errors.New("chatgpt_models_unavailable")
	}
	var catalog struct {
		Models []map[string]json.RawMessage `json:"models"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 4<<20)).Decode(&catalog); err != nil {
		return nil, nil, err
	}
	return planCatalog(catalog.Models)
}

type chatGPTModelRoute struct {
	slug        string
	serviceTier string
}

type chatGPTSpeed struct {
	suffix string
	label  string
	tier   string
}

func chatGPTSpeeds(model map[string]json.RawMessage) []chatGPTSpeed {
	var advertised []struct {
		ID string `json:"id"`
	}
	var tierIDs []string
	if raw := model["service_tiers"]; len(raw) > 0 && !bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		if json.Unmarshal(raw, &advertised) != nil {
			return nil
		}
		for _, tier := range advertised {
			tierIDs = append(tierIDs, tier.ID)
		}
	} else if json.Unmarshal(model["additional_speed_tiers"], &tierIDs) != nil {
		return nil
	}

	var fast, ultrafast bool
	for _, tier := range tierIDs {
		switch tier {
		case "fast", "priority":
			fast = true
		case "ultrafast":
			ultrafast = true
		}
	}
	speeds := make([]chatGPTSpeed, 0, 2)
	if fast {
		speeds = append(speeds, chatGPTSpeed{suffix: "/fast", label: "快速", tier: "priority"})
	}
	if ultrafast {
		speeds = append(speeds, chatGPTSpeed{suffix: "/ultrafast", label: "极速", tier: "ultrafast"})
	}
	return speeds
}

func planCatalog(models []map[string]json.RawMessage) ([]byte, map[string]chatGPTModelRoute, error) {
	aliases := make(map[string]chatGPTModelRoute)
	visible := make([]map[string]json.RawMessage, 0, len(models))
	for _, model := range models {
		var slug, visibility, name string
		if json.Unmarshal(model["slug"], &slug) != nil || !officialSlug.MatchString(slug) ||
			json.Unmarshal(model["visibility"], &visibility) != nil || visibility != "list" {
			continue
		}
		alias := chatGPTPrefix + slug
		if _, duplicate := aliases[alias]; duplicate {
			continue
		}
		json.Unmarshal(model["display_name"], &name)
		if name == "" {
			name = slug
		}
		name += " · ChatGPT"
		base := maps.Clone(model)
		base["slug"], _ = json.Marshal(alias)
		route := chatGPTModelRoute{slug: slug}
		speeds := chatGPTSpeeds(model)
		if len(speeds) > 0 {
			// The model choice now owns its speed, independently of Desktop's speed controls.
			delete(base, "additional_speed_tiers")
			delete(base, "service_tiers")
			delete(base, "default_service_tier")
			route.serviceTier = "default"
			base["display_name"], _ = json.Marshal(name + " · 标准")
		} else {
			base["display_name"], _ = json.Marshal(name)
		}
		aliases[alias] = route
		visible = append(visible, base)
		for _, speed := range speeds {
			variantAlias := alias + speed.suffix
			variant := maps.Clone(base)
			variant["slug"], _ = json.Marshal(variantAlias)
			variant["display_name"], _ = json.Marshal(name + " · " + speed.label)
			aliases[variantAlias] = chatGPTModelRoute{slug: slug, serviceTier: speed.tier}
			visible = append(visible, variant)
		}
	}
	if len(aliases) == 0 {
		return nil, nil, errors.New("chatgpt_models_unavailable")
	}
	data, err := json.Marshal(map[string]any{"models": visible})
	return data, aliases, err
}

type chatGPTRoute struct {
	baseURL string
	aliases map[string]chatGPTModelRoute
	access  func(context.Context) (string, error)
}

func (p *chatGPTRoute) serve(w http.ResponseWriter, request *http.Request, model string, body []byte) {
	route, ok := p.aliases[model]
	if !ok {
		reject(w, http.StatusBadRequest, "chatgpt_model_unavailable", "This model is unavailable in the authorized ChatGPT account.")
		return
	}
	if request.URL.Path != "/responses" || request.URL.RawQuery != "" {
		reject(w, http.StatusBadRequest, "chatgpt_route_not_supported", "This ChatGPT account connection supports streaming Responses.")
		return
	}
	payload, err := planRequest(body, route)
	if err != nil {
		reject(w, http.StatusBadRequest, "chatgpt_request_not_supported", "ChatGPT account requests require the full input history.")
		return
	}
	token, err := p.access(request.Context())
	if err != nil {
		reject(w, http.StatusUnauthorized, "chatgpt_sign_in_required", "Reopen the launcher and reconnect your ChatGPT account.")
		return
	}
	target, err := url.Parse(p.baseURL)
	if err != nil {
		reject(w, http.StatusBadGateway, "chatgpt_unavailable", "Could not reach ChatGPT.")
		return
	}
	request.Header = http.Header{
		"Authorization": {"Bearer " + token},
		"Content-Type":  {"application/json"},
		"Accept":        {"text/event-stream"},
		"User-Agent":    {"Codex-Third-Party-Launcher"},
	}
	request.Body = io.NopCloser(bytes.NewReader(payload))
	request.ContentLength = int64(len(payload))
	request.TransferEncoding = nil
	reverseProxy(target).ServeHTTP(w, request)
}

func planRequest(body []byte, route chatGPTModelRoute) ([]byte, error) {
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, err
	}
	if previous := payload["previous_response_id"]; len(previous) != 0 && string(previous) != "null" {
		return nil, errors.New("ChatGPT requires full conversation history")
	}
	for _, field := range strings.Fields("background conversation max_output_tokens max_tool_calls metadata moderation multi_agent prompt prompt_cache_retention safety_identifier temperature top_logprobs top_p truncation user previous_response_id") {
		delete(payload, field)
	}
	// Keep the tool types available to this Responses connection. Local Codex
	// tools are normally supplied as functions or function namespaces.
	if raw := payload["tools"]; len(raw) > 0 {
		var tools []json.RawMessage
		if err := json.Unmarshal(raw, &tools); err != nil {
			return nil, err
		}
		var allowed []json.RawMessage
		for _, tool := range tools {
			var entry struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(tool, &entry) != nil {
				continue
			}
			switch entry.Type {
			case "function", "custom", "namespace", "web_search", "web_search_preview":
				allowed = append(allowed, tool)
			}
		}
		if len(allowed) == 0 {
			delete(payload, "tools")
			delete(payload, "tool_choice")
			delete(payload, "parallel_tool_calls")
		} else {
			payload["tools"], _ = json.Marshal(allowed)
		}
	}
	if input := bytes.TrimSpace(payload["input"]); len(input) > 0 && input[0] == '"' {
		var text string
		if err := json.Unmarshal(input, &text); err != nil {
			return nil, err
		}
		payload["input"], _ = json.Marshal([]any{map[string]any{"role": "user", "content": []any{
			map[string]string{"type": "input_text", "text": text},
		}}})
	}
	if input := bytes.TrimSpace(payload["input"]); len(input) == 0 || input[0] != '[' {
		return nil, errors.New("ChatGPT requires input messages")
	}
	payload["model"], _ = json.Marshal(route.slug)
	if route.serviceTier != "" {
		payload["service_tier"], _ = json.Marshal(route.serviceTier)
	}
	payload["store"] = json.RawMessage("false")
	payload["stream"] = json.RawMessage("true")
	return json.Marshal(payload)
}
