package resona

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const testBotToken = "123456:abcdefghijklmnopqrstuvwxyz_123456"

func TestPluginConfigurationAndSecrets(t *testing.T) {
	s := testServer(t)
	defer s.plugins.Wait()
	h, token := s.Handler(), loginToken(t, s)
	if w := request(h, "GET", "/api/v1/plugins", "", ""); w.Code != 401 {
		t.Fatal("plugin configuration must require authentication")
	}
	body := `{"enabled":false,"token":"` + testBotToken + `","api_url":"","whitelist":"42\n123"}`
	w := request(h, "PUT", "/api/v1/plugins/musicsaverbot", body, token)
	if w.Code != 200 || strings.Contains(w.Body.String(), testBotToken) || !strings.Contains(w.Body.String(), `"has_token":true`) {
		t.Fatalf("secret disclosure or failed save: %d %s", w.Code, w.Body.String())
	}
	w = request(h, "PUT", "/api/v1/plugins/musicsaverbot", `{"token":"","enabled":false,"api_url":"","whitelist":"42"}`, token)
	if w.Code != 200 || s.store.pluginSettings().Music.Token != testBotToken {
		t.Fatal("blank token must retain existing secret")
	}
	w = request(h, "PUT", "/api/v1/plugins/telegramlocalapi",
		`{"enabled":false,"api_id":1234,"api_hash":"0123456789abcdef0123456789abcdef","port":8081,"proxy_password":"private-password"}`, token)
	if w.Code != 200 || strings.Contains(w.Body.String(), "private-password") || strings.Contains(w.Body.String(), "0123456789abcdef") {
		t.Fatalf("API secrets disclosed: %s", w.Body.String())
	}
	w = request(h, "PUT", "/api/v1/plugins/telegramlocalapi", `{"enabled":false,"port":8081,"api_hash":"","proxy_password":""}`, token)
	if w.Code != 200 || s.store.pluginSettings().Telegram.ProxyPassword != "private-password" {
		t.Fatal("blank API secrets must retain saved values")
	}
	for _, body := range []string{
		`{"enabled":true,"api_url":"local"}`,
		`{"api_url":"http://user:password@localhost"}`,
		`{"api_url":"file:///etc/passwd"}`,
		`{"api_url":"http://localhost?token=secret"}`,
		`{"whitelist":"42\nbad"}`,
		`{"token":"malformed"}`,
	} {
		if w := request(h, "PUT", "/api/v1/plugins/musicsaverbot", body, token); w.Code != 400 {
			t.Fatalf("invalid config accepted: %s: %d", body, w.Code)
		}
	}
	disk, err := OpenStore(s.config.DataDir)
	if err != nil || disk.pluginSettings().Music.Token != testBotToken {
		t.Fatal("plugin configuration not durable")
	}
	// An unrelated library mutation must keep plugin credentials.
	if err := s.store.update(func(st *libraryState) error { st.Jobs = nil; return nil }); err != nil ||
		s.store.pluginSettings().Music.Token != testBotToken {
		t.Fatal("library update lost plugin configuration")
	}
	original := s.store.path
	s.store.path = filepath.Join(s.config.DataDir, "missing", "library.json")
	w = request(h, "PUT", "/api/v1/plugins/musicsaverbot", `{"token":"111:abcdefghijklmnopqrstuvwxyz_123456","enabled":false}`, token)
	s.store.path = original
	if w.Code != 500 || s.store.pluginSettings().Music.Token != testBotToken {
		t.Fatal("failed configuration write must roll back")
	}
}

func TestTelegramReceiveAndImport(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg required")
	}
	s := testServer(t)
	source := filepath.Join(t.TempDir(), "song.mp3")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "0.2",
		"-metadata", "title=Song", "-metadata", "artist=Artist", "-metadata", "album=Album", source).CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg: %s: %v", out, err)
	}
	audio, _ := os.ReadFile(source)
	content := audio
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/getFile") {
			jsonResponse(w, 200, map[string]any{"ok": true, "result": map[string]any{"file_path": "music/file", "file_size": len(content)}})
		} else if strings.Contains(r.URL.Path, "/file/bot") {
			w.Write(content)
		} else {
			t.Errorf("unexpected request: %s", r.URL.Path)
		}
	}))
	defer server.Close()
	settings := PluginSettings{Music: MusicSaverSettings{Token: testBotToken, APIURL: server.URL, Whitelist: "42"}}
	message := &telegramMessage{Audio: &telegramFile{ID: "file", Name: "../untrusted.mp3", Title: "Song", Performer: "Artist", Size: int64(len(audio))}, Caption: "专辑：Album"}
	message.From.ID = 7
	if _, accepted, err := s.plugins.receive(context.Background(), settings, message); err != nil || accepted {
		t.Fatal("non-whitelisted user accepted")
	}
	message.From.ID = 42
	name, accepted, err := s.plugins.receive(context.Background(), settings, message)
	if err != nil || !accepted || name != "Song-Artist.mp3" {
		t.Fatalf("save: %s %v %v", name, accepted, err)
	}
	// Re-delivery after a crash must not overwrite or duplicate content.
	if second, _, err := s.plugins.receive(context.Background(), settings, message); err != nil || second != name {
		t.Fatal("duplicate delivery not idempotent")
	}
	requireMusicPermissions(t, s.store.pluginInbox(s.config))
	if _, err := s.scanner.Start(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	s.scanner.Wait()
	tracks := s.store.Tracks()
	if len(tracks) != 1 || tracks[0].Title != "Song" || tracks[0].Artist != "Artist" {
		t.Fatalf("bot audio not imported: %+v", tracks)
	}
	track, _ := s.store.Track(tracks[0].ID)
	if !within(s.config.LibraryDir, track.Path) || filepath.Base(track.Path) != "Song-Artist.mp3" {
		t.Fatal("audio not organized")
	}
	// A late lyric document should be available beside the already imported audio.
	content = []byte("[00:00.00]A test line")
	message.Audio = nil
	message.Document = &telegramFile{ID: "lyrics", Name: "Song-Artist.txt", Size: int64(len(content))}
	if _, _, err := s.plugins.receive(context.Background(), settings, message); err != nil {
		t.Fatal(err)
	}
	lyric, err := s.scanner.readLyrics(context.Background(), track)
	if err != nil || !strings.Contains(lyric.Text, "A test line") {
		t.Fatalf("late sidecar unavailable: %+v %v", lyric, err)
	}
	requireMusicPermissions(t, s.config.LibraryDir)
}

func TestTelegramRejectsUnsafeAndIncompleteFiles(t *testing.T) {
	s := testServer(t)
	outside := filepath.Join(t.TempDir(), "secret")
	os.WriteFile(outside, []byte("private"), 0600)
	for _, path := range []string{outside, "../escape", "bad?query", "ok"} {
		t.Run(path, func(t *testing.T) {
			mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.HasSuffix(r.URL.Path, "/getFile") {
					jsonResponse(w, 200, map[string]any{"ok": true, "result": map[string]any{"file_path": path, "file_size": 8}})
					return
				}
				w.Write([]byte("short"))
			}))
			defer mock.Close()
			settings := PluginSettings{Music: MusicSaverSettings{Token: testBotToken, APIURL: mock.URL}}
			root := s.store.pluginInbox(s.config)
			_, err := s.plugins.saveTelegramFile(context.Background(), settings, &telegramFile{ID: "id", Size: 8}, root, root, "audio.mp3", 1024)
			if err == nil || strings.Contains(err.Error(), testBotToken) {
				t.Fatalf("unsafe/incomplete file accepted, or token in error: %v", err)
			}
			entries, _ := os.ReadDir(root)
			if len(entries) != 0 {
				t.Fatalf("failed download left visible files: %+v", entries)
			}
		})
	}
}

func TestBotPollingOffsetAndCancellation(t *testing.T) {
	s := testServer(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var requests atomic.Int32
	acknowledged := make(chan struct{})
	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Offset int64 }
		json.NewDecoder(r.Body).Decode(&body)
		if requests.Add(1) == 1 {
			jsonResponse(w, 200, map[string]any{"ok": true, "result": []any{map[string]any{"update_id": 77, "message": map[string]any{"text": "ignored"}}}})
			return
		}
		if body.Offset != 78 {
			t.Errorf("expected acknowledged offset 78, got %d", body.Offset)
		}
		close(acknowledged)
		<-r.Context().Done()
	}))
	defer mock.Close()
	settings := PluginSettings{Music: MusicSaverSettings{Enabled: true, Token: testBotToken, APIURL: mock.URL}}
	s.store.update(func(st *libraryState) error { st.Plugins = settings; return nil })
	done := make(chan struct{})
	go func() { s.plugins.runBot(ctx, settings); close(done) }()
	select {
	case <-acknowledged:
	case <-time.After(5 * time.Second):
		t.Fatal("polling did not advance")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("polling did not cancel promptly")
	}
	s.scanner.Wait()
	if s.store.pluginSettings().Offset != 78 {
		t.Fatal("offset not durable")
	}
}

func TestPluginCacheCleanupPreservesSessionAndNewFiles(t *testing.T) {
	s := testServer(t)
	dir := s.plugins.localDir()
	cache := filepath.Join(dir, "files", "bot", "music")
	os.MkdirAll(cache, 0700)
	session := filepath.Join(dir, "session.binlog")
	old, fresh := filepath.Join(cache, "old.mp3"), filepath.Join(cache, "new.mp3")
	for _, path := range []string{session, old, fresh} {
		os.WriteFile(path, []byte("keep data"), 0600)
	}
	before := time.Now().Add(-48 * time.Hour)
	os.Chtimes(session, before, before)
	os.Chtimes(old, before, before)
	external := t.TempDir()
	secret := filepath.Join(external, "keep")
	os.WriteFile(secret, []byte("keep"), 0600)
	os.Chtimes(secret, before, before)
	os.Symlink(external, filepath.Join(cache, "link"))
	if err := s.plugins.cleanCache(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("old download not removed")
	}
	for _, path := range []string{session, fresh, secret} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("cleanup removed protected file: %s", path)
		}
	}
}

func TestTelegramErrorsNeverExposeToken(t *testing.T) {
	s := testServer(t)
	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(409)
		io.Copy(w, bytes.NewBufferString(`{"ok":false,"description":"secret `+testBotToken+`"}`))
	}))
	defer mock.Close()
	err := s.plugins.telegram(context.Background(), mock.URL, testBotToken, "getUpdates", nil, nil)
	if err == nil || !strings.Contains(err.Error(), "冲突") || strings.Contains(err.Error(), testBotToken) {
		t.Fatalf("unsafe API error: %v", err)
	}
}

func TestTelegramRateLimit(t *testing.T) {
	s := testServer(t)
	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jsonResponse(w, 429, map[string]any{"ok": false, "parameters": map[string]int{"retry_after": 17}})
	}))
	defer mock.Close()
	err := s.plugins.telegram(context.Background(), mock.URL, testBotToken, "getUpdates", nil, nil)
	var limited telegramRateLimit
	if !errors.As(err, &limited) || limited.wait != 17*time.Second {
		t.Fatalf("rate limit lost: %v", err)
	}
}

func TestLocalAPIServiceLifecycle(t *testing.T) {
	s := testServer(t)
	// The native service starts without a token, and never contacts Telegram.
	token := loginToken(t, s)
	w := request(s.Handler(), "PUT", "/api/v1/plugins/telegramlocalapi",
		`{"enabled":true,"api_id":123,"api_hash":"0123456789abcdef0123456789abcdef","port":18081}`, token)
	if w.Code != 200 {
		t.Fatalf("enable local API: %d %s", w.Code, w.Body.String())
	}
	defer s.plugins.Wait()
	waitRunning := func() {
		t.Helper()
		for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); {
			s.plugins.mu.RLock()
			state := s.plugins.status["telegramlocalapi"].State
			s.plugins.mu.RUnlock()
			if state == "running" {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("Go local API did not start")
	}
	waitRunning()
	worker := s.plugins.workers["telegramlocalapi"]
	// Updating an unrelated, disabled music bot must leave the local service alone.
	w = request(s.Handler(), "PUT", "/api/v1/plugins/musicsaverbot", `{"enabled":false}`, token)
	if w.Code != 200 || s.plugins.workers["telegramlocalapi"].done != worker.done {
		t.Fatal("unrelated plugin update restarted local service")
	}
	w = request(s.Handler(), "POST", "/api/v1/plugins/telegramlocalapi/restart", `{}`, token)
	if w.Code != 200 {
		t.Fatal("restart failed")
	}
	select {
	case <-worker.done:
	default:
		t.Fatal("restart did not wait for the old listener to close")
	}
	waitRunning()
	worker = s.plugins.workers["telegramlocalapi"]
	w = request(s.Handler(), "PUT", "/api/v1/plugins/telegramlocalapi", `{"enabled":false,"port":18081}`, token)
	if w.Code != 200 {
		t.Fatal("disable failed")
	}
	select {
	case <-worker.done:
	case <-time.After(time.Second):
		t.Fatal("disabled local API still running")
	}
}
