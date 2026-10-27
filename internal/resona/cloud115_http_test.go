package resona

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestCloudDirectoryRetryAndCancellation(t *testing.T) {
	for _, status := range []int{405, 429, 500} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			s := testServer(t)
			seedCloud(t, s)
			calls := 0
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				w.Header().Set("Retry-After", "1")
				w.WriteHeader(status)
			}))
			defer api.Close()
			err := s.cloud.requestAt(t.Context(), api.URL, "GET", "/files", url.Values{"private": {"secret"}}, cloudDirectoryUA, nil)
			var rejection *cloudHTTPError
			want := 4
			if status == 500 {
				want = 1
			}
			if calls != want || !errors.As(err, &rejection) || rejection.Status != status || strings.Contains(err.Error(), "secret") {
				t.Fatal("incorrect bounded retry or unsafe diagnostic", calls, err)
			}
			if status != 500 {
				// The last rejection's cooldown also applies to subsequent requests.
				if time.Until(s.cloud.nextRequest) < 500*time.Millisecond {
					t.Fatal("lost final cooldown")
				}
				ctx, cancel := context.WithCancel(t.Context())
				cancel()
				if err := s.cloud.requestAt(ctx, api.URL, "GET", "/files", nil, cloudDirectoryUA, nil); !errors.Is(err, context.Canceled) || calls != want {
					t.Fatal("cancelled cooldown made a request", calls, err)
				}
			}
			if s.cloud.snapshot().Cookie == "" {
				t.Fatal("HTTP rejection cleared login")
			}
		})
	}
}

func TestCloudDirectoryTransientRejectionRecovers(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	calls := 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls < 3 {
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(405)
			return
		}
		jsonResponse(w, 200, map[string]any{"state": true, "cid": 0, "path": []any{map[string]any{"cid": 0}}, "count": 0, "data": []any{}})
	}))
	defer api.Close()
	s.cloud.webURL = api.URL
	if err := s.cloud.generate(t.Context()); err != nil || calls != 3 {
		t.Fatal("transient 405 did not recover", calls, err)
	}
}

func TestCloudRetryAfterAndDirectTransport(t *testing.T) {
	for _, tt := range []struct {
		header  string
		attempt int
		want    time.Duration
	}{
		{"", 0, time.Second}, {"invalid", 1, 2 * time.Second}, {"-1", 2, 4 * time.Second},
		{" 3 ", 0, 3 * time.Second}, {"9223372036854775807", 0, 120 * time.Second},
		{time.Now().Add(-time.Minute).UTC().Format(http.TimeFormat), 0, time.Second},
	} {
		if got := cloudRetryDelay(tt.header, tt.attempt); got != tt.want {
			t.Fatal(tt, got)
		}
	}
	if delay := cloudRetryDelay(time.Now().Add(time.Minute).UTC().Format(http.TimeFormat), 0); delay < 58*time.Second || delay > time.Minute {
		t.Fatal("HTTP-date Retry-After", delay)
	}
	s := testServer(t)
	transport, ok := s.cloud.client.Transport.(*http.Transport)
	if !ok || transport.Proxy != nil || transport == http.DefaultTransport {
		t.Fatal("115 must use its own direct transport")
	}
}

func TestCloudRetryCooldownCanBeCancelled(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	calls := 0
	first := make(chan struct{})
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("Retry-After", "120")
		w.WriteHeader(429)
		close(first)
	}))
	defer api.Close()
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() { done <- s.cloud.requestAt(ctx, api.URL, "GET", "/files", nil, cloudDirectoryUA, nil) }()
	<-first
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) || calls != 1 {
			t.Fatal("cancelled retry continued", calls, err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancellation waited for upstream cooldown")
	}
}
