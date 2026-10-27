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
	"sync"
	"testing"
	"time"
)

func testConfig(t *testing.T) Config {
	t.Helper()
	dir := t.TempDir()
	dir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	c := Config{DataDir: filepath.Join(dir, "data"), InboxDir: filepath.Join(dir, "inbox"),
		LibraryDir: filepath.Join(dir, "library"), Username: "admin"}
	for _, path := range []string{c.DataDir, c.InboxDir, c.LibraryDir} {
		if err := os.MkdirAll(path, 0750); err != nil {
			t.Fatal(err)
		}
	}
	return c
}

func testServer(t *testing.T) *Server {
	t.Helper()
	s, err := NewServer(context.Background(), testConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.auth.setup("a-test-password-123"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func request(h http.Handler, method, path, body, token string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func loginToken(t *testing.T, s *Server) string {
	t.Helper()
	w := request(s.Handler(), "POST", "/api/v1/auth/login", `{"username":"admin","password":"a-test-password-123"}`, "")
	if w.Code != 200 {
		t.Fatalf("login: %d %s", w.Code, w.Body.String())
	}
	var body struct{ Token string }
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || len(body.Token) != 64 {
		t.Fatalf("missing session: %s", w.Body.String())
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 1 || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatal("session cookie protections missing")
	}
	return body.Token
}

func TestAuthenticationAndBoundaries(t *testing.T) {
	s := testServer(t)
	h := s.Handler()
	for _, path := range []string{"/api/v1/tracks", "/api/v1/albums", "/api/v1/artists", "/api/v1/system", "/api/v1/jobs", "/api/v1/tracks/test/stream", "/api/v1/tracks/test/cover", "/api/v1/tracks/test/lyrics"} {
		if w := request(h, "GET", path, "", ""); w.Code != 401 {
			t.Fatalf("%s exposed: %d", path, w.Code)
		}
	}
	if w := request(h, "POST", "/api/v1/auth/login", `{"username":"admin","password":"wrong"}`, ""); w.Code != 401 {
		t.Fatal("wrong password accepted")
	}
	if w := request(h, "POST", "/api/v1/auth/login", `{} {}`, ""); w.Code != 400 {
		t.Fatal("trailing JSON accepted")
	}
	token := loginToken(t, s)
	if w := request(h, "GET", "/api/v1/system", "", token); w.Code != 200 {
		t.Fatal("valid token rejected")
	}
	r := httptest.NewRequest("POST", "/api/v1/jobs/scan", strings.NewReader("{}"))
	r.Header.Set("Origin", "https://attacker.example")
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("cross-origin write accepted")
	}
	r = httptest.NewRequest("POST", "/api/v1/jobs/scan", strings.NewReader("{}"))
	r.Header.Set("Authorization", "Bearer "+token)
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 415 {
		t.Fatal("non-JSON write accepted")
	}
	if w := request(h, "POST", "/api/v1/auth/logout", "{}", token); w.Code != 200 {
		t.Fatal("logout failed")
	}
	if w := request(h, "GET", "/api/v1/tracks", "", token); w.Code != 401 {
		t.Fatal("logged-out token remained valid")
	}
}

func TestLoginThrottleAndExpiry(t *testing.T) {
	s := testServer(t)
	r := httptest.NewRequest("POST", "/", nil)
	for i := 0; i < 8; i++ {
		if _, err := s.auth.login(r, "admin", "wrong"); !errors.Is(err, errCredentials) {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	if _, err := s.auth.login(r, "admin", "a-test-password-123"); !errors.Is(err, errThrottled) {
		t.Fatal("rate limit bypassed")
	}
	s.auth.mu.Lock()
	for key, a := range s.auth.attempts {
		a.Since = time.Now().Add(-16 * time.Minute)
		s.auth.attempts[key] = a
	}
	s.auth.mu.Unlock()
	if _, err := s.auth.login(r, "admin", "a-test-password-123"); err != nil {
		t.Fatal("rate limit did not recover", err)
	}
}

func TestFirstRunSetupIsRequiredPersistentAndCreateOnly(t *testing.T) {
	c := testConfig(t)
	s, err := NewServer(context.Background(), c)
	if err != nil {
		t.Fatal("server should start without a password", err)
	}
	h := s.Handler()
	w := request(h, "GET", "/api/v1/auth/status", "", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"initialized":false`) {
		t.Fatal("first-run status missing", w.Body.String())
	}
	w = request(h, "POST", "/api/v1/auth/login", `{"username":"admin","password":"a-test-password-123"}`, "")
	if w.Code != 428 {
		t.Fatal("uninitialized login accepted", w.Code)
	}
	if w := request(h, "POST", "/api/v1/auth/setup", `{"password":"short"}`, ""); w.Code != 400 {
		t.Fatal("weak setup password accepted")
	}
	w = request(h, "POST", "/api/v1/auth/setup", `{"password":"a-test-password-123"}`, "")
	if w.Code != 201 {
		t.Fatal("setup failed", w.Code, w.Body.String())
	}
	saved, err := os.ReadFile(filepath.Join(c.DataDir, "admin.json"))
	if err != nil || bytes.Contains(saved, []byte("a-test-password-123")) {
		t.Fatal("plaintext password persisted", err)
	}
	if info, err := os.Stat(filepath.Join(c.DataDir, "admin.json")); err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("credential file permissions must be 0600")
	}
	if w := request(h, "POST", "/api/v1/auth/setup", `{"password":"different-password-123"}`, ""); w.Code != 409 {
		t.Fatal("existing admin password was reset")
	}
	restarted, err := NewServer(context.Background(), c)
	if err != nil || !restarted.auth.initialized() {
		t.Fatal("credentials lost after restart", err)
	}
	loginToken(t, restarted)
}

func TestSetupPasswordLength(t *testing.T) {
	for _, tc := range []struct {
		name, password string
		status         int
	}{
		{"seven ASCII characters", "1234567", 400},
		{"eight ASCII characters", "12345678", 201},
		{"seven Unicode characters", strings.Repeat("中", 7), 400},
		{"eight Unicode characters", strings.Repeat("中", 8), 201},
		{"over byte limit", strings.Repeat("a", 1025), 400},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, err := NewServer(context.Background(), testConfig(t))
			if err != nil {
				t.Fatal(err)
			}
			body, err := json.Marshal(map[string]string{"password": tc.password})
			if err != nil {
				t.Fatal(err)
			}
			w := request(s.Handler(), "POST", "/api/v1/auth/setup", string(body), "")
			if w.Code != tc.status {
				t.Fatalf("setup: got %d, want %d: %s", w.Code, tc.status, w.Body.String())
			}
			if tc.status == 201 {
				body, err = json.Marshal(map[string]string{"username": "admin", "password": tc.password})
				if err != nil {
					t.Fatal(err)
				}
				if w := request(s.Handler(), "POST", "/api/v1/auth/login", string(body), ""); w.Code != 200 {
					t.Fatalf("login with accepted password: %d %s", w.Code, w.Body.String())
				}
			}
		})
	}
}

func TestConcurrentSetupCanOnlySucceedOnce(t *testing.T) {
	c := testConfig(t)
	a, err := NewAuth(c)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 4)
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- a.setup("a-test-password-123")
		}()
	}
	wg.Wait()
	close(results)
	success := 0
	for err := range results {
		if err == nil {
			success++
		} else if !errors.Is(err, errAlreadyConfigured) {
			t.Fatal(err)
		}
	}
	if success != 1 {
		t.Fatal("concurrent setup must have exactly one winner", success)
	}
	os.WriteFile(a.path, []byte("{broken"), 0600)
	if _, err := NewAuth(c); err == nil {
		t.Fatal("corrupt credentials silently reopened setup")
	}
}

func TestRangeStreamingAndFavorites(t *testing.T) {
	s := testServer(t)
	token := loginToken(t, s)
	path := filepath.Join(s.config.LibraryDir, "test.mp3")
	if err := os.WriteFile(path, []byte("0123456789"), 0600); err != nil {
		t.Fatal(err)
	}
	track := Track{ID: "abc", Title: "<script>alert(1)</script>", Artist: "Artist", AlbumArtist: "Artist", Album: "Album", Format: "mp3", AddedAt: time.Now()}
	if err := s.store.update(func(st *libraryState) error {
		st.Tracks["abc"] = DiskTrack{Track: track, File: path}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("GET", "/api/v1/tracks/abc/stream", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Range", "bytes=2-5")
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)
	if w.Code != 206 || w.Body.String() != "2345" || w.Header().Get("Content-Range") != "bytes 2-5/10" {
		t.Fatalf("range failed: %d %s", w.Code, w.Body.String())
	}
	w = request(s.Handler(), "HEAD", "/api/v1/tracks/abc/stream", "", token)
	if w.Code != 200 || w.Body.Len() != 0 {
		t.Fatal("HEAD streaming failed")
	}
	w = request(s.Handler(), "PUT", "/api/v1/tracks/abc/favorite", `{"favorite":true}`, token)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	w = request(s.Handler(), "GET", "/api/v1/tracks?favorite=true&limit=1", "", token)
	if w.Code != 200 || strings.Contains(w.Body.String(), path) || !strings.Contains(w.Body.String(), `"total":1`) {
		t.Fatal("favorite filtering or private path failed", w.Body.String())
	}
	if w := request(s.Handler(), "PUT", "/api/v1/tracks/abc/favorite", `{}`, token); w.Code != 400 {
		t.Fatal("missing favorite silently accepted")
	}
	outside := filepath.Join(t.TempDir(), "secret.mp3")
	os.WriteFile(outside, []byte("secret"), 0600)
	os.Remove(path)
	os.Symlink(outside, path)
	if w := request(s.Handler(), "GET", "/api/v1/tracks/abc/stream", "", token); w.Code != 404 {
		t.Fatal("stream followed symlink outside library")
	}
}

func TestStoreAtomicityAndRecovery(t *testing.T) {
	dir := t.TempDir()
	s, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.update(func(st *libraryState) error {
		st.Tracks["test"] = DiskTrack{Track: Track{ID: "test"}, File: "/private/music"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.update(func(st *libraryState) error {
		delete(st.Tracks, "test")
		return errors.New("rollback")
	}); err == nil {
		t.Fatal("mutation error was lost")
	}
	reopened, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if track, ok := reopened.Track("test"); !ok || track.Path != "/private/music" {
		t.Fatal("persisted path was lost")
	}
	original := s.path
	s.path = filepath.Join(dir, "missing", "db.json")
	if err := s.update(func(st *libraryState) error { delete(st.Tracks, "test"); return nil }); err == nil {
		t.Fatal("write failure ignored")
	}
	if _, ok := s.Track("test"); !ok {
		t.Fatal("failed disk write changed in-memory library")
	}
	s.path = original
	corrupt := t.TempDir()
	os.WriteFile(filepath.Join(corrupt, "library.sqlite"), []byte("{broken"), 0600)
	if _, err := OpenStore(corrupt); err == nil {
		t.Fatal("corrupt library silently replaced")
	}
}

func TestMetadataMatching(t *testing.T) {
	r := recording{Title: "Hello!", Score: 100, Length: 200000}
	r.Credit = append(r.Credit, struct {
		Name   string `json:"name"`
		Artist struct {
			Name string `json:"name"`
		} `json:"artist"`
	}{Name: "Artist"})
	track := Track{Title: "Hello", Artist: "Artist", Duration: 200}
	if !candidateMatches(track, recordingCandidates([]recording{r})[0], 5) {
		t.Fatal("exact recording did not match")
	}
	track.Artist = "Someone Else"
	if candidateMatches(track, recordingCandidates([]recording{r})[0], 5) {
		t.Fatal("wrong artist matched")
	}
	track.Artist, track.Duration = "Artist", 250
	if candidateMatches(track, recordingCandidates([]recording{r})[0], 5) {
		t.Fatal("wrong duration matched")
	}
	if within("/music", "/music-other/song.mp3") || !within("/music", "/music/album/song.mp3") ||
		within("/music", "/secret") || safeComponent("../A/B:Title") != "_A_B_Title" {
		t.Fatal("path boundary or sanitization failed")
	}
	if len(safeComponent(strings.Repeat("中", 200))) > 120 {
		t.Fatal("Unicode path component too long")
	}
}

func TestScraperPreservesLocalMetadata(t *testing.T) {
	var received string
	fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		received = r.URL.Query().Get("query")
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"recordings":[{"id":"recording","title":"Hello","score":100,"length":200000,"artist-credit":[{"name":"Artist","artist":{"name":"Artist"}}],"releases":[{"id":"release","title":"Online Album","date":"2020-01-01","status":"Official"}]}]}`)
	}))
	defer fixture.Close()
	server := testServer(t)
	scraper := &Scraper{Client: fixture.Client(), Endpoint: fixture.URL}
	server.scanner.scraper = scraper
	track := Track{Title: "Hello", Artist: "Artist", Duration: 200}
	if err := server.scanner.enrich(context.Background(), &track, "musicbrainz"); err != nil {
		t.Fatal(err)
	}
	if track.Album != "Online Album" || track.Year != "2020" || !strings.Contains(received, `artist:"Artist"`) {
		t.Fatal("online enrichment failed", track, received)
	}
	scraper.last = time.Time{}
	track.Album, track.Year = "Local Album", "1999"
	if err := server.scanner.enrich(context.Background(), &track, "musicbrainz"); !errors.Is(err, errNoMetadata) {
		t.Fatalf("mismatched album accepted: %v", err)
	}
	if track.Album != "Local Album" || track.Year != "1999" {
		t.Fatal("scraper overwrote existing tags")
	}
}

func TestScanOrganizesThenDeletesSourceAndDeduplicates(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("integration requires ffmpeg")
	}
	if _, err := exec.LookPath("ffprobe"); err != nil {
		t.Skip("integration requires ffprobe")
	}
	c := testConfig(t)
	src := filepath.Join(c.InboxDir, "source.mp3")
	cmd := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3",
		"-metadata", "title=First Song", "-metadata", "artist=Resona Test", "-metadata", "album=Test Album", "-metadata", "track=1", src)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatal(err, string(out))
	}
	os.WriteFile(filepath.Join(c.InboxDir, "source.lrc"), []byte("[00:00.10]Hello"), 0600)
	original, _ := os.ReadFile(src)
	audio := streamDigest(t, src, "0:a:0")
	store, err := OpenStore(c.DataDir)
	if err != nil {
		t.Fatal(err)
	}
	scanner := NewScanner(c, store)
	if _, err := scanner.Start(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	scanner.Wait()
	tracks := store.Tracks()
	if len(tracks) != 1 {
		t.Fatalf("expected one imported track, jobs=%+v", store.Jobs())
	}
	track, _ := store.Track(tracks[0].ID)
	if !within(c.LibraryDir, track.Path) || !strings.Contains(track.Path, "Resona Test/Test Album/") {
		t.Fatal("music was not organized", track.Path)
	}
	if filepath.Base(track.Path) != "First Song-Resona Test.mp3" {
		t.Fatal("incorrect organized filename", track.Path)
	}
	items := store.Jobs()[0].Items
	if len(items) != 1 || items[0].TrackID != track.ID || items[0].State != "imported" || items[0].Filename != "source.mp3" {
		t.Fatal("missing per-file progress", items)
	}
	items[0].Title = "mutated"
	if store.Jobs()[0].Items[0].Title == "mutated" {
		t.Fatal("job details share mutable storage")
	}
	organized, _ := os.ReadFile(track.Path)
	if len(original) == 0 || bytes.Equal(original, organized) || !bytes.Equal(audio, streamDigest(t, track.Path, "0:a:0")) {
		t.Fatal("expected tag-only lyrics write without changing audio")
	}
	metadata, err := readMetadata(context.Background(), track.Path)
	if err != nil || metadata.TagLyrics != "[00:00.10]Hello" || track.HasEmbeddedLyrics == nil || !*track.HasEmbeddedLyrics || items[0].Duration <= 0 {
		t.Fatal("scan did not write lyrics/duration", metadata, items, err)
	}
	for _, path := range []string{src, filepath.Join(c.InboxDir, "source.lrc")} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("successful import retained source", path, err)
		}
	}
	lrc, err := os.ReadFile(strings.TrimSuffix(track.Path, ".mp3") + ".lrc")
	if err != nil || string(lrc) != "[00:00.10]Hello" {
		t.Fatal("lyrics not imported", err)
	}
	os.WriteFile(filepath.Join(c.InboxDir, "duplicate.mp3"), original, 0600)
	if _, err := scanner.Start(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	scanner.Wait()
	if len(store.Tracks()) != 1 || store.Jobs()[0].Skipped != 2 || store.Jobs()[0].Imported != 0 {
		t.Fatal("deduplication failed", store.Jobs())
	}
	if _, err := os.Stat(filepath.Join(c.InboxDir, "duplicate.mp3")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("verified identical import was not cleaned", err)
	}
	for _, item := range store.Jobs()[0].Items {
		if item.State != "skipped" || item.TrackID != track.ID {
			t.Fatal("missing duplicate detail", item)
		}
	}
	if err := store.update(func(st *libraryState) error {
		d := st.Tracks[track.ID]
		d.Title, d.Artist, d.Album, d.Year = "Corrected Song", "Correct Artist", "Correct Album", "2026"
		d.MetadataLocked = true
		d.Lyrics = &SavedLyrics{Text: "[00:01]Saved lyrics", Source: "LRCLIB"}
		st.Tracks[track.ID] = d
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := scanner.Start(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	scanner.Wait()
	corrected, _ := store.Track(track.ID)
	if corrected.Title != "Corrected Song" || corrected.Artist != "Correct Artist" || corrected.Album != "Correct Album" ||
		!corrected.MetadataLocked || filepath.Base(corrected.Path) != "Corrected Song-Correct Artist.mp3" {
		t.Fatal("rescrape reverted correction", corrected)
	}
	if _, err := os.Stat(track.Path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("old library filename remains", err)
	}
	if data, err := os.ReadFile(strings.TrimSuffix(corrected.Path, ".mp3") + ".lrc"); err != nil || string(data) != "[00:00.10]Hello" {
		t.Fatal("lyrics did not follow rename", err)
	}
	after, _ := os.ReadFile(corrected.Path)
	if !bytes.Equal(organized, after) {
		t.Fatal("renaming changed audio content")
	}
	if store.state.Tracks[track.ID].Lyrics == nil {
		t.Fatal("rescrape discarded saved lyrics")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := scanner.Start(ctx, false); err == nil {
		t.Fatal("scan started after shutdown")
	}
}

func TestCopyRefusesConflictingDestination(t *testing.T) {
	c := testConfig(t)
	scanner := NewScanner(c, nil)
	src := filepath.Join(c.InboxDir, "test.mp3")
	os.WriteFile(src, []byte("source"), 0600)
	id, size, _ := hashFile(context.Background(), src)
	track := Track{ID: id, Size: size, Title: "Title", Artist: "Artist", Album: "Album", Format: "mp3"}
	dest, err := scanner.copyTrack(context.Background(), src, track)
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(dest, []byte("different"), 0600)
	second, err := scanner.copyTrack(context.Background(), src, track)
	if err != nil || second == dest || !strings.Contains(second, id[:12]) {
		t.Fatal("conflict was not safely disambiguated", second, err)
	}
	content, _ := os.ReadFile(dest)
	if string(content) != "different" {
		t.Fatal("existing content changed")
	}
}

func TestConcurrentStoreUpdates(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := store.update(func(st *libraryState) error {
				id := randomID(4)
				st.Tracks[id] = DiskTrack{Track: Track{ID: id}}
				return nil
			}); err != nil {
				t.Error(err)
			}
			_ = store.Tracks()
		}()
	}
	wg.Wait()
	if len(store.Tracks()) != 10 {
		t.Fatal("concurrent update was lost")
	}
}
