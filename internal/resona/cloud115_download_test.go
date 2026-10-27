package resona

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestCloudAndroidDirectDownloadResponseValidation(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	key := cloudTestCipher(t)
	for _, scenario := range []struct {
		name, id, pickcode, link string
		valid                    bool
	}{
		{"valid", "7", "abcdefghijklmnopq", "https://cdnfhnfile.115cdn.net/song.flac?f=1", true},
		{"wrong file", "8", "abcdefghijklmnopq", "https://cdnfhnfile.115cdn.net/song.flac", false},
		{"wrong pickcode", "7", "other", "https://cdnfhnfile.115cdn.net/song.flac", false},
		{"cookie required", "7", "abcdefghijklmnopq", "https://cdnfhnfile.115cdn.net/song.flac?f=3", false},
		{"untrusted", "7", "abcdefghijklmnopq", "https://outside.invalid/song.flac", false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "POST" || r.URL.Path != "/android/2.0/ufile/download" ||
					r.URL.RawQuery != "" || r.UserAgent() != "Player" {
					t.Error("incorrect Android download request")
				}
				data, _ := json.Marshal(map[string]string{"url": scenario.link, "file_id": scenario.id, "pick_code": scenario.pickcode})
				cloudResponse(w, cloudSignedResponse(t, key, data))
			}))
			defer api.Close()
			s.cloud.apiURL = api.URL
			_, err := s.cloud.fetchDownloadURL(t.Context(), RemoteFile{Account: "42", FileID: "7", PickCode: "abcdefghijklmnopq"},
				"Player", "/android/2.0/ufile/download")
			if (err == nil) != scenario.valid {
				t.Fatal("incorrect download validation", err)
			}
		})
	}
}

func TestCloudDownloadRecoversFromAndroidRestrictionAndCachesFallback(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	key := cloudTestCipher(t)
	chrome, android := 0, 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/android/2.0/ufile/download" {
			android++
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(405)
			return
		}
		chrome++
		cloudDownloadResponse(t, w, r, key, "7", "https://cdnfhnfile.115cdn.net/song.flac?f=1")
	}))
	defer api.Close()
	s.cloud.apiURL = api.URL
	file := RemoteFile{Account: "42", FileID: "7", PickCode: "abcdefghijklmnopq"}
	for _, ua := range []string{"Player A", "Player B"} {
		link, err := s.cloud.downloadURL(t.Context(), file, ua)
		if err != nil || !strings.HasPrefix(link, "https://cdnfhnfile.115cdn.net/") {
			t.Fatal("download fallback failed", link, err)
		}
	}
	if chrome != 2 || android != 2 {
		t.Fatal("restriction was not bounded or working endpoint was not reused", chrome, android)
	}
}

func TestCloudDownloadPostRetryAndCancellation(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	key := cloudTestCipher(t)
	calls := 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(405)
			return
		}
		cloudDownloadResponse(t, w, r, key, "7", "https://cdnfhnfile.115cdn.net/song.mp3?f=1")
	}))
	defer api.Close()
	s.cloud.apiURL = api.URL
	file := RemoteFile{Account: "42", FileID: "7", PickCode: "abcdefghijklmnopq"}
	if _, err := s.cloud.downloadURL(t.Context(), file, "Player"); err != nil || calls != 2 {
		t.Fatal("transient download rejection was not retried", calls, err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := s.cloud.downloadURL(ctx, file, "Another Player"); err != context.Canceled {
		t.Fatal("cancelled resolution continued", err)
	}
}

func TestCloudDownloadKeepsRestrictionWhenFallbackFails(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	calls := 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path == "/android/2.0/ufile/download" {
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(405)
		} else {
			w.WriteHeader(404)
		}
	}))
	defer api.Close()
	s.cloud.apiURL = api.URL
	_, err := s.cloud.downloadURL(t.Context(), RemoteFile{Account: "42", FileID: "7", PickCode: "abcdefghijklmnopq"}, "Player")
	if !cloudRestricted(err) || calls != 3 || !strings.Contains(errors.Unwrap(err).Error(), "404") ||
		!strings.Contains(err.Error(), "HTTP 兼容模式") || s.cloud.snapshot().Cookie == "" {
		t.Fatal("failed fallback hid the restriction or discarded login", calls, err)
	}
}

func TestCloudDownloadHTTPRequiresSavedOptIn(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	key := cloudTestCipher(t)
	httpCalls, secureCalls := 0, 0
	s.cloud.client.Transport = catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "proapi.115.com" || r.Header.Get("Cookie") != s.cloud.summary().Cookie {
			t.Fatal("unexpected upstream host or Cookie")
		}
		w := httptest.NewRecorder()
		if r.URL.Scheme == "https" {
			secureCalls++
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(405)
		} else {
			httpCalls++
			if r.URL.Path != "/android/2.0/ufile/download" {
				t.Error("HTTP compatibility did not use the reference Android endpoint")
			}
			cloudDownloadResponse(t, w, r, key, "7", "https://cdnfhnfile.115cdn.net/song.flac?f=1")
		}
		return w.Result(), nil
	})
	file := RemoteFile{Account: "42", FileID: "7", PickCode: "abcdefghijklmnopq"}
	if _, err := s.cloud.downloadURL(t.Context(), file, "Player"); !cloudRestricted(err) || secureCalls != 4 || httpCalls != 0 {
		t.Fatal("HTTPS rejection silently downgraded or was not bounded", secureCalls, httpCalls, err)
	}
	token := loginToken(t, s)
	save := func(enabled bool) {
		t.Helper()
		settings := s.cloud.summary().Settings
		settings.DownloadHTTP = enabled
		body, _ := json.Marshal(settings)
		w := request(s.Handler(), "PUT", "/api/v1/cloud115", string(body), token)
		if w.Code != 200 || s.cloud.summary().Settings.DownloadHTTP != enabled || len(s.cloud.links) != 0 || s.cloud.downloadPath != "" {
			t.Fatal("mode change did not invalidate links and learned endpoint", w.Code, w.Body.String())
		}
		data, err := os.ReadFile(s.store.path)
		var saved libraryState
		if err != nil || json.Unmarshal(data, &saved) != nil || saved.Cloud.Settings.DownloadHTTP != enabled {
			t.Fatal("mode was not persisted", err)
		}
	}
	save(true)
	for range 2 {
		if _, err := s.cloud.downloadURL(t.Context(), file, "Player"); err != nil {
			t.Fatal("reference HTTP protocol failed", err)
		}
	}
	if httpCalls != 1 || secureCalls != 4 {
		t.Fatal("download was not cached", httpCalls, secureCalls)
	}
	save(false)
	if _, err := s.cloud.downloadURL(t.Context(), file, "Player"); !cloudRestricted(err) || httpCalls != 1 || secureCalls != 8 {
		t.Fatal("HTTPS mode reused the HTTP-mode link or downgraded", secureCalls, httpCalls, err)
	}
}

func TestCloudDownloadNeverFollowsCookieRedirects(t *testing.T) {
	for _, target := range []string{"http://proapi.115.com/android/2.0/ufile/download", "https://outside.invalid/steal"} {
		t.Run(target, func(t *testing.T) {
			s := testServer(t)
			seedCloud(t, s)
			calls := 0
			s.cloud.client.Transport = catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
				calls++
				if calls != 1 || r.URL.Scheme != "https" || r.URL.Host != "proapi.115.com" {
					t.Error("Cookie-bearing redirect was followed")
				}
				w := httptest.NewRecorder()
				w.Header().Set("Location", target)
				w.WriteHeader(302)
				return w.Result(), nil
			})
			_, err := s.cloud.downloadURL(t.Context(), RemoteFile{Account: "42", FileID: "7", PickCode: "abcdefghijklmnopq"}, "Player")
			if err == nil || calls != 1 {
				t.Fatal("unexpected redirect resolution", calls, err)
			}
		})
	}
}

func TestCloudDownloadFallbackDoesNotHideExpiredLogin(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	s.cloud.client.Transport = catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
		w := httptest.NewRecorder()
		if r.URL.Path == "/android/2.0/ufile/download" {
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(405)
		} else {
			w.WriteHeader(401)
		}
		return w.Result(), nil
	})
	_, err := s.cloud.downloadURL(t.Context(), RemoteFile{Account: "42", FileID: "7", PickCode: "abcdefghijklmnopq"}, "Player")
	if !errors.Is(err, errCloudAuth) || cloudRestricted(err) || s.cloud.summary().Cookie != "" {
		t.Fatal("expired login was reported as a protocol compatibility issue", err)
	}
}
