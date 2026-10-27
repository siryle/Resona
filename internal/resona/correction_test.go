package resona

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func addTestTrack(t *testing.T, s *Server) Track {
	t.Helper()
	track := Track{ID: strings.Repeat("a", 64), Title: "青花瓷", Artist: "周杰伦", AlbumArtist: "周杰伦",
		Album: "我很忙", Duration: 239, Format: "mp3", Favorite: true, AddedAt: time.Now().UTC()}
	path := filepath.Join(s.config.LibraryDir, "song.mp3")
	if err := os.WriteFile(path, []byte("unchanged audio"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := s.store.update(func(st *libraryState) error {
		st.Tracks[track.ID] = DiskTrack{Track: track, File: path}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	track.Path = path
	return track
}

func TestMetadataCorrectionValidationPersistenceAndPrivacy(t *testing.T) {
	s := testServer(t)
	track := addTestTrack(t, s)
	token := loginToken(t, s)
	h := s.Handler()
	path := "/api/v1/tracks/" + track.ID + "/metadata"
	body := `{"title":" Corrected ","artist":"Artist","album":"Album","album_artist":"","year":"2026","genre":"Pop","number":2,"disc":1}`
	if w := request(h, "PUT", path, body, ""); w.Code != 401 {
		t.Fatal("unauthenticated correction accepted", w.Code)
	}
	for _, invalid := range []string{
		`{"title":"","artist":"Artist"}`, `{"title":"x","artist":""}`,
		`{"title":"x","artist":"y","number":-1}`, `{"title":"x","artist":"y","year":"26"}`,
		`{"title":"x","artist":"y","mbid":"invalid"}`, `{"title":"x\nz","artist":"y"}`,
		`{"title":"x","artist":"y","file":"/etc/passwd"}`, `{"title":"x","artist":"y","duration":42}`,
	} {
		if w := request(h, "PUT", path, invalid, token); w.Code != 400 {
			t.Fatalf("invalid correction accepted: %s: %d", invalid, w.Code)
		}
	}
	w := request(h, "PUT", path, body, token)
	if w.Code != 200 || strings.Contains(w.Body.String(), track.Path) {
		t.Fatal("correction failed or leaked path", w.Code, w.Body.String())
	}
	reopened, err := OpenStore(s.config.DataDir)
	if err != nil {
		t.Fatal(err)
	}
	updated, _ := reopened.Track(track.ID)
	if updated.Title != "Corrected" || updated.AlbumArtist != "Artist" || !updated.MetadataLocked ||
		!updated.Favorite || updated.Duration != track.Duration || !updated.AddedAt.Equal(track.AddedAt) || updated.Path != filepath.Join(s.config.LibraryDir, "Artist", "Album", "Corrected-Artist.mp3") {
		t.Fatal("correction did not preserve identity or persist", updated)
	}
	if _, err := os.Stat(track.Path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("old correction path remains", err)
	}
	audio, _ := os.ReadFile(updated.Path)
	if string(audio) != "unchanged audio" {
		t.Fatal("correction modified audio")
	}
	if w := request(h, "PUT", "/api/v1/tracks/missing/metadata", body, token); w.Code != 404 {
		t.Fatal("missing track accepted", w.Code)
	}
}

func TestCandidateSearchIsReadOnlyAndReturnsReleaseChoices(t *testing.T) {
	s := testServer(t)
	track := addTestTrack(t, s)
	var query string
	fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query = r.URL.Query().Get("query")
		io.WriteString(w, `{"recordings":[{"id":"11111111-1111-1111-1111-111111111111","title":"Correct Song","score":88,"length":239000,"artist-credit":[{"name":"Correct Artist"}],"releases":[{"id":"22222222-2222-2222-2222-222222222222","title":"First Album","date":"2020-02-01","status":"Official"},{"id":"33333333-3333-3333-3333-333333333333","title":"Reissue","date":"2026","status":"Official"},{"title":"Bootleg","status":"Bootleg"}]}]}`)
	}))
	defer fixture.Close()
	s.scanner.scraper = &Scraper{Client: fixture.Client(), Endpoint: fixture.URL}
	token := loginToken(t, s)
	path := "/api/v1/tracks/" + track.ID + "/matches?title=Correct+Song&artist="
	if w := request(s.Handler(), "GET", path, "", ""); w.Code != 401 {
		t.Fatal("candidate search exposed")
	}
	w := request(s.Handler(), "GET", path, "", token)
	if w.Code != 200 || strings.Contains(w.Body.String(), "Bootleg") {
		t.Fatal("candidate search failed", w.Code, w.Body.String())
	}
	var body struct{ Items []TrackMetadata }
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || len(body.Items) != 2 {
		t.Fatal("release choices missing", w.Body.String(), err)
	}
	if body.Items[1].Album != "Reissue" || body.Items[1].Year != "2026" || query != `recording:"Correct Song"` {
		t.Fatal("incorrect search or release mapping", query, body)
	}
	current, _ := s.store.Track(track.ID)
	if current.Title != track.Title || current.MetadataLocked {
		t.Fatal("search modified metadata")
	}
}

func lyricFixture(title, artist, album, synced, plain string, duration float64) string {
	data, _ := json.Marshal(map[string]any{"trackName": title, "artistName": artist, "albumName": album,
		"duration": duration, "syncedLyrics": synced, "plainLyrics": plain})
	return string(data)
}

func TestLyricsProviderChecksIdentityAndContent(t *testing.T) {
	track := Track{Title: "青花瓷", Artist: "周杰伦", Album: "我很忙", Duration: 239}
	for _, tc := range []struct {
		name, response string
		status         int
		want, synced   bool
	}{
		{"synced", lyricFixture(track.Title, track.Artist, track.Album, "[00:01.00]天青色", "plain", 240), 200, true, true},
		{"plain", lyricFixture(track.Title, track.Artist, track.Album, "", "天青色\n等烟雨", 239), 200, true, false},
		{"wrong artist", lyricFixture(track.Title, "Cover Artist", track.Album, "[00:01]x", "", 239), 200, false, false},
		{"wrong title", lyricFixture("Live Version", track.Artist, track.Album, "[00:01]x", "", 239), 200, false, false},
		{"wrong album", lyricFixture(track.Title, track.Artist, "Live", "[00:01]x", "", 239), 200, false, false},
		{"wrong duration", lyricFixture(track.Title, track.Artist, track.Album, "[00:01]x", "", 250), 200, false, false},
		{"empty", lyricFixture(track.Title, track.Artist, track.Album, "", "", 239), 200, false, false},
		{"oversized", lyricFixture(track.Title, track.Artist, track.Album, strings.Repeat("x", maxLyricsSize+1), "", 239), 200, false, false},
		{"malformed", "<html>upstream failure</html>", 200, false, false},
		{"missing", `{}`, 404, false, false},
		{"unavailable", `{}`, 503, false, false},
		{"instrumental", `{"trackName":"青花瓷","artistName":"周杰伦","albumName":"我很忙","duration":239,"instrumental":true}`, 200, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				q := r.URL.Query()
				if q.Get("track_name") != track.Title || q.Get("artist_name") != track.Artist || q.Get("duration") != "239" || !strings.HasPrefix(r.UserAgent(), "Resona/") {
					t.Error("incorrect provider request", r.URL)
				}
				w.WriteHeader(tc.status)
				io.WriteString(w, tc.response)
			}))
			defer fixture.Close()
			provider := LyricsProvider{Client: fixture.Client(), Endpoint: fixture.URL}
			result, err := provider.Fetch(context.Background(), track)
			if tc.want {
				if err != nil || result.Synced != tc.synced || result.Source != "LRCLIB" || result.Text == "" {
					t.Fatal(result, err)
				}
			} else if err == nil {
				t.Fatal("invalid lyrics accepted", result)
			}
		})
	}
}

func TestLyricsScrapingPersistenceNoOverwriteAndCorrectionInvalidation(t *testing.T) {
	s := testServer(t)
	track := addTestTrack(t, s)
	var calls atomic.Int32
	fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		io.WriteString(w, lyricFixture(track.Title, track.Artist, track.Album, "[00:01.00]天青色等烟雨", "", 239))
	}))
	defer fixture.Close()
	s.scanner.lyricProvider = &LyricsProvider{Client: fixture.Client(), Endpoint: fixture.URL}
	token := loginToken(t, s)
	path := "/api/v1/tracks/" + track.ID + "/lyrics"
	if w := request(s.Handler(), "POST", path+"/scrape", `{}`, ""); w.Code != 401 {
		t.Fatal("unauthenticated scrape accepted")
	}
	if w := request(s.Handler(), "POST", path+"/scrape", `{}`, token); w.Code != 200 {
		t.Fatal("scrape failed", w.Code, w.Body.String())
	}
	if w := request(s.Handler(), "POST", path+"/scrape", `{}`, token); w.Code != 409 || calls.Load() != 1 {
		t.Fatal("existing lyrics overwritten or unnecessary provider request", w.Code, calls.Load())
	}
	reopened, err := NewServer(context.Background(), s.config)
	if err != nil {
		t.Fatal(err)
	}
	newToken := loginToken(t, reopened)
	w := request(reopened.Handler(), "GET", path, "", newToken)
	if w.Code != 200 || w.Body.String() != "[00:01.00]天青色等烟雨" || w.Header().Get("X-Lyrics-Source") != "LRCLIB" {
		t.Fatal("lyrics did not survive restart", w.Code, w.Body.String())
	}
	// Changing only a track number preserves matching lyrics; changing identity clears the cache.
	m := metadataOf(track)
	m.Number = 3
	body, _ := json.Marshal(m)
	if w := request(reopened.Handler(), "PUT", "/api/v1/tracks/"+track.ID+"/metadata", string(body), newToken); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if w := request(reopened.Handler(), "GET", path, "", newToken); w.Code != 200 {
		t.Fatal("unrelated edit cleared lyrics")
	}
	m.Artist = "Correct Artist"
	body, _ = json.Marshal(m)
	request(reopened.Handler(), "PUT", "/api/v1/tracks/"+track.ID+"/metadata", string(body), newToken)
	if w := request(reopened.Handler(), "GET", path, "", newToken); w.Code != 404 {
		t.Fatal("old identity lyrics still served")
	}
}

func TestLyricsReplacementPreservesLocalFileAndSurvivesProviderFailure(t *testing.T) {
	s := testServer(t)
	track := addTestTrack(t, s)
	sidecar := strings.TrimSuffix(track.Path, ".mp3") + ".lrc"
	if err := os.WriteFile(sidecar, []byte("[00:01]Local lyrics"), 0600); err != nil {
		t.Fatal(err)
	}
	var fail atomic.Bool
	fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if fail.Load() {
			w.WriteHeader(500)
			return
		}
		io.WriteString(w, lyricFixture(track.Title, track.Artist, track.Album, "[00:01]Online lyrics", "", 239))
	}))
	defer fixture.Close()
	s.scanner.lyricProvider = &LyricsProvider{Client: fixture.Client(), Endpoint: fixture.URL}
	token := loginToken(t, s)
	path := "/api/v1/tracks/" + track.ID + "/lyrics"
	if w := request(s.Handler(), "POST", path+"/scrape", `{}`, token); w.Code != 409 {
		t.Fatal("local lyrics overwritten implicitly")
	}
	if w := request(s.Handler(), "POST", path+"/scrape", `{"replace":true}`, token); w.Code != 200 {
		t.Fatal("explicit replacement failed", w.Body.String())
	}
	local, _ := os.ReadFile(sidecar)
	if string(local) != "[00:01]Local lyrics" {
		t.Fatal("source LRC was changed")
	}
	fail.Store(true)
	s.scanner.lyricProvider.next = time.Time{}
	if w := request(s.Handler(), "POST", path+"/scrape", `{"replace":true}`, token); w.Code != 502 {
		t.Fatal("provider failure not reported", w.Code)
	}
	if w := request(s.Handler(), "GET", path, "", token); w.Body.String() != "[00:01]Online lyrics" {
		t.Fatal("failed replacement discarded saved lyrics", w.Body.String())
	}
}

func TestLyricsRejectsStaleFetchAfterConcurrentCorrection(t *testing.T) {
	s := testServer(t)
	track := addTestTrack(t, s)
	started, finish := make(chan struct{}), make(chan struct{})
	fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-finish
		io.WriteString(w, lyricFixture(track.Title, track.Artist, track.Album, "[00:01]Old lyrics", "", 239))
	}))
	defer fixture.Close()
	s.scanner.lyricProvider = &LyricsProvider{Client: fixture.Client(), Endpoint: fixture.URL}
	token := loginToken(t, s)
	result := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		result <- request(s.Handler(), "POST", "/api/v1/tracks/"+track.ID+"/lyrics/scrape", `{}`, token)
	}()
	<-started
	m := metadataOf(track)
	m.Title = "Corrected"
	body, _ := json.Marshal(m)
	request(s.Handler(), "PUT", "/api/v1/tracks/"+track.ID+"/metadata", string(body), token)
	close(finish)
	if w := <-result; w.Code != 409 {
		t.Fatal("stale lyrics saved after correction", w.Code, w.Body.String())
	}
	if _, err := s.scanner.readLyrics(context.Background(), track); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("stale lyrics persisted", err)
	}
}

func TestLyricsProviderHonorsRetryAfter(t *testing.T) {
	var calls atomic.Int32
	fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Retry-After", "120")
		w.WriteHeader(429)
	}))
	defer fixture.Close()
	p := LyricsProvider{Client: fixture.Client(), Endpoint: fixture.URL}
	track := Track{Title: "Song", Artist: "Artist", Duration: 100}
	p.Fetch(context.Background(), track)
	if time.Until(p.next) < 119*time.Second {
		t.Fatal("Retry-After ignored")
	}
	p.Fetch(context.Background(), track)
	if calls.Load() != 1 {
		t.Fatal("retried provider before cooldown expired")
	}
}
