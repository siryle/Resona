package resona

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
)

func TestCloudPlaybackFailureLog(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	file := RemoteFile{Account: "42", FileID: "7", PickCode: "abcdefghijklmnopq"}
	id := cloudTrackID("42", "7")
	if err := s.store.update(func(st *libraryState) error {
		st.Tracks[id] = DiskTrack{Track: Track{ID: id, Title: "Failed Song", Artist: "Artist"}, Remote: &file}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	s.cloud.client.Transport = catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
		w := httptest.NewRecorder()
		w.WriteHeader(404)
		return w.Result(), nil
	})
	token := loginToken(t, s)
	if w := request(s.Handler(), "HEAD", "/api/v1/tracks/"+id+"/stream?refresh=1", "", token); w.Code != 502 {
		t.Fatal("unexpected playback failure", w.Code)
	}
	w := request(s.Handler(), "GET", "/api/v1/logs?category=playback&level=WARN&search=Failed%20Song", "", token)
	var result struct{ Items []LogEntry }
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || len(result.Items) != 1 {
		t.Fatal("playback failure category/filter missing", w.Body.String(), err)
	}
	for _, value := range []string{"地址获取失败", "status=502", "HTTP 404", "method=HEAD", "refresh=true", "elapsed_ms="} {
		if !strings.Contains(result.Items[0].Message, value) {
			t.Fatal("missing playback failure detail", value, result.Items[0])
		}
	}
}

func TestLogFilteringPersistenceAndPrivacy(t *testing.T) {
	s := testServer(t)
	token := loginToken(t, s)
	h := s.Handler()
	if w := request(h, "GET", "/api/v1/logs", "", ""); w.Code != 401 {
		t.Fatal("logs exposed", w.Code)
	}
	s.logger.Debug("debug event")
	s.logger.With("category", "scan").Warn("scan warning")
	s.logger.With("category", "plugin").Error("plugin error")
	s.logger.With("category", "settings").Info("settings saved")
	for _, query := range []string{"level=TRACE", "category=unknown", "limit=0", "limit=2001", "limit=bad"} {
		if w := request(h, "GET", "/api/v1/logs?"+query, "", token); w.Code != 400 {
			t.Fatal("invalid filter accepted", query, w.Code)
		}
	}
	w := request(h, "GET", "/api/v1/logs?level=WARN&category=scan&search=warning", "", token)
	var result struct {
		Items  []LogEntry
		Counts map[string]int
	}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || w.Code != 200 || len(result.Items) != 1 || result.Counts["WARN"] != 1 {
		t.Fatal("filter failed", w.Body.String(), err)
	}
	if result.Items[0].Message != "scan warning" {
		t.Fatal(result)
	}
	reopened, err := openLogBook(s.config.DataDir)
	if err != nil || len(reopened.entries) != 5 {
		t.Fatal("logs not persistent", err, reopened)
	}
	for _, method := range []string{"DELETE"} {
		r := httptest.NewRequest(method, "/api/v1/logs", nil)
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("Origin", "https://attacker.example")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatal("cross-origin clear accepted")
		}
	}
	if w := request(h, "DELETE", "/api/v1/logs", "", token); w.Code != 204 {
		t.Fatal("clear failed", w.Code)
	}
	reopened, err = openLogBook(s.config.DataDir)
	if err != nil || len(reopened.entries) != 1 || !strings.Contains(reopened.entries[0].Message, "清空") {
		t.Fatal("clear was not persisted/audited", err)
	}
	console := &strings.Builder{}
	logger := slog.New(&logHandler{book: reopened, console: slog.NewTextHandler(console, nil)})
	reopened.registerSecrets(PluginSettings{Music: MusicSaverSettings{Token: "123456:abcdefghijklmnopqrstuvwxyz_123456"}, Telegram: TelegramSettings{APIHash: "privateHashValue"}})
	logger.Error("https://user:password@host.test/api?signature=privateQuery token=unknownValue privateHashValue 123456:abcdefghijklmnopqrstuvwxyz_123456",
		"password", "first second third", "authorization", "Bearer sensitiveValue")
	for _, text := range []string{console.String(), string(mustReadFile(t, reopened.path))} {
		for _, secret := range []string{"privateHashValue", "abcdefghijklmnopqrstuvwxyz", "unknownValue", "privateQuery", "first second", "sensitiveValue", "user:password"} {
			if strings.Contains(text, secret) {
				t.Fatal("credential leaked", secret, text)
			}
		}
	}
}

func mustReadFile(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestLogBoundsRotationAndConcurrentWrites(t *testing.T) {
	b, err := openLogBook(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	logger := slog.New(&logHandler{book: b, console: slog.NewTextHandler(io.Discard, nil)})
	var workers sync.WaitGroup
	for i := 0; i < 4; i++ {
		workers.Go(func() {
			for j := 0; j < 600; j++ {
				logger.DebugContext(context.Background(), strings.Repeat("x", 4000))
			}
		})
	}
	workers.Wait()
	if len(b.entries) != maxLogEntries {
		t.Fatal("unbounded logs", len(b.entries))
	}
	for _, path := range []string{b.path, b.path + ".1"} {
		info, err := os.Stat(path)
		if err != nil || info.Size() > maxLogFileSize+(32<<10) || info.Mode().Perm() != 0600 {
			t.Fatal("rotation/permissions failed", info, err)
		}
	}
	reopened, err := openLogBook(strings.TrimSuffix(b.path, "/runtime.log"))
	if err != nil || len(reopened.entries) == 0 || len(reopened.entries) > maxLogEntries {
		t.Fatal("rotation reload failed", err)
	}
}
