package main

import (
	"bufio"
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

type settings struct {
	BaseURL      string `json:"baseURL"`
	UpstreamKey  string `json:"upstreamKey"`
	LocalKey     string `json:"localKey"`
	ModelPattern string `json:"modelPattern"`
}

const maxRequestBytes = 64 << 20

func main() {
	log.SetOutput(io.Discard)
	if err := run(); err != nil {
		os.Exit(1)
	}
}

func run() error {
	input := bufio.NewReaderSize(os.Stdin, 64<<10)
	line, err := input.ReadSlice('\n')
	if err != nil {
		return err
	}
	var config settings
	if err := json.Unmarshal(line, &config); err != nil {
		return err
	}
	handler, err := makeHandler(config)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer listener.Close()
	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       60 * time.Second,
		IdleTimeout:       60 * time.Second,
		ErrorLog:          log.New(io.Discard, "", 0),
	}
	go func() {
		io.Copy(io.Discard, input)
		server.Close()
	}()
	if _, err := fmt.Fprintln(os.Stdout, "http://"+listener.Addr().String()); err != nil {
		return err
	}
	if err := server.Serve(listener); errors.Is(err, http.ErrServerClosed) {
		return nil
	} else {
		return err
	}
}

func makeHandler(config settings) (http.Handler, error) {
	upstream, err := url.Parse(config.BaseURL)
	if err != nil || upstream.Hostname() == "" || upstream.User != nil || upstream.RawQuery != "" || upstream.Fragment != "" ||
		(upstream.Scheme != "https" && !(upstream.Scheme == "http" && isLoopback(upstream.Hostname()))) ||
		config.UpstreamKey == "" || config.LocalKey == "" {
		return nil, errors.New("invalid gateway configuration")
	}
	excluded, err := regexp.Compile(config.ModelPattern)
	if err != nil {
		return nil, err
	}

	proxy := &httputil.ReverseProxy{
		Rewrite: func(request *httputil.ProxyRequest) {
			request.SetURL(upstream)
			request.Out.Header.Set("Authorization", "Bearer "+config.UpstreamKey)
			request.Out.Header.Del("X-Api-Key")
			request.Out.Header.Del("Cookie")
		},
		ModifyResponse: func(response *http.Response) error {
			if response.StatusCode >= 300 && response.StatusCode < 400 {
				return errors.New("gateway redirect")
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			reject(w, http.StatusBadGateway, "upstream_unavailable", "The gateway request failed.")
		},
	}
	return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if subtle.ConstantTimeCompare([]byte(request.Header.Get("Authorization")), []byte("Bearer "+config.LocalKey)) != 1 {
			reject(w, http.StatusUnauthorized, "invalid_api_key", "Invalid local gateway credential.")
			return
		}
		// GPT exclusion requires seeing the model before sending any request bytes upstream.
		if request.URL.IsAbs() || request.Header.Get("Upgrade") != "" {
			reject(w, http.StatusBadRequest, "unsupported_transport", "GPT exclusion uses HTTP Responses.")
			return
		}
		path := request.URL.Path
		if request.Method == http.MethodGet && path == "/models" {
			proxy.ServeHTTP(w, request)
			return
		}
		if request.Method != http.MethodPost || (path != "/responses" && path != "/responses/compact" && path != "/responses/input_tokens") {
			reject(w, http.StatusBadRequest, "unsupported_route", "This route cannot be checked for GPT exclusion.")
			return
		}
		mediaType, _, _ := mime.ParseMediaType(request.Header.Get("Content-Type"))
		if mediaType != "application/json" || request.URL.Query().Has("model") {
			reject(w, http.StatusBadRequest, "invalid_request", "Send a JSON request with one explicit model.")
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, request.Body, maxRequestBytes))
		if err != nil {
			var tooLarge *http.MaxBytesError
			if errors.As(err, &tooLarge) {
				reject(w, http.StatusRequestEntityTooLarge, "request_too_large", "Request exceeds the local size limit.")
			} else {
				reject(w, http.StatusBadRequest, "invalid_request", "Could not read the request body.")
			}
			return
		}
		model, err := requestModel(body)
		if err != nil {
			reject(w, http.StatusBadRequest, "invalid_request", "Send a JSON request with one explicit model.")
			return
		}
		if excluded.MatchString(model) {
			reject(w, http.StatusBadRequest, "model_excluded", "This model is blocked by local GPT exclusion.")
			return
		}
		request.Body = io.NopCloser(bytes.NewReader(body))
		request.ContentLength = int64(len(body))
		request.TransferEncoding = nil
		proxy.ServeHTTP(w, request)
	}), nil
}

func requestModel(body []byte) (string, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return "", errors.New("invalid JSON object")
	}
	var model string
	for decoder.More() {
		field, err := decoder.Token()
		if err != nil {
			return "", err
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return "", err
		}
		if key, ok := field.(string); ok && strings.EqualFold(key, "model") {
			if key != "model" || model != "" || json.Unmarshal(value, &model) != nil || strings.TrimSpace(model) == "" {
				return "", errors.New("invalid or duplicate model")
			}
			model = strings.TrimSpace(model)
		}
	}
	if token, err := decoder.Token(); err != nil || token != json.Delim('}') {
		return "", errors.New("invalid JSON object")
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) || model == "" {
		return "", errors.New("missing model or invalid trailing data")
	}
	return model, nil
}

func isLoopback(host string) bool {
	return strings.EqualFold(host, "localhost") || net.ParseIP(host).IsLoopback()
}

func reject(w http.ResponseWriter, status int, code string, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]string{"type": "invalid_request_error", "code": code, "message": message},
	})
}
