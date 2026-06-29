package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func withTestUpstream(t *testing.T, h http.HandlerFunc) {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)

	oldUpstream := upstreamURL
	oldClient := httpClient
	upstreamURL = srv.URL
	httpClient = srv.Client()
	t.Cleanup(func() {
		upstreamURL = oldUpstream
		httpClient = oldClient
	})
}

func TestDoUpstreamRetriesTransientStatus(t *testing.T) {
	attempts := 0
	withTestUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		attempts++
		if attempts == 1 {
			http.Error(w, "bad gateway", http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"text":"ok"}`))
	})

	resp, out, err := doUpstream([]byte("body"), "multipart/form-data; boundary=x", "token", "")
	if err != nil {
		t.Fatalf("doUpstream returned error: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if attempts != 2 {
		t.Fatalf("attempts = %d, want 2", attempts)
	}
	if !strings.Contains(string(out), `"ok"`) {
		t.Fatalf("body = %q, want ok text", out)
	}
}

func TestDoUpstreamDoesNotRetryClientStatus(t *testing.T) {
	attempts := 0
	withTestUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		attempts++
		http.Error(w, "forbidden", http.StatusForbidden)
	})

	resp, _, err := doUpstream([]byte("body"), "multipart/form-data; boundary=x", "token", "")
	if err != nil {
		t.Fatalf("doUpstream returned error: %v", err)
	}
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", resp.StatusCode)
	}
	if attempts != 1 {
		t.Fatalf("attempts = %d, want no retry", attempts)
	}
}
