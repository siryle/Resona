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
	"reflect"
	"strings"
	"testing"
)

func TestDurationMatchingPrefersConsistentSourcesAndVersions(t *testing.T) {
	s := testServer(t)
	if err := s.store.update(func(st *libraryState) error {
		st.Sources = SourceSettings{MetadataPriority: []string{"qq", "netease"}, MetadataDisabled: []string{}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	calls := []string{}
	s.scanner.catalog.Client.Transport = catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
		calls = append(calls, r.URL.Host)
		body := catalogFixtures[r.URL.Scheme+"://"+r.URL.Host+r.URL.Path]
		if r.URL.Host == "u.y.qq.com" {
			body = strings.ReplaceAll(body, `"interval":239`, `"interval":243`)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
	})
	track := Track{Title: "Song", Artist: "Artist", Duration: 239}
	if err := s.scanner.enrich(context.Background(), &track, "auto"); err != nil || track.MetadataSource != "netease" ||
		!reflect.DeepEqual(calls, []string{"u.y.qq.com", "music.163.com"}) {
		t.Fatal("nearby higher-priority version beat consistent version", track, calls, err)
	}
	items := []MetadataCandidate{
		{TrackMetadata: TrackMetadata{Title: "Wrong", Artist: "Artist", Album: "Album"}, Duration: 239},
		{TrackMetadata: TrackMetadata{Title: "Song", Artist: "Artist", Album: "Album"}, Duration: 243},
		{TrackMetadata: TrackMetadata{Title: "Song", Artist: "Artist", Album: "Album"}, Duration: 239.1},
		{TrackMetadata: TrackMetadata{Title: "Song", Artist: "Artist", Album: "Album"}},
	}
	rankCandidates(track, items)
	if !candidateMatches(track, items[0], 1) || items[0].Duration != 239.1 || candidateMatches(track, items[3], 5) {
		t.Fatal("duration/identity ranking failed", items)
	}
	// One provider can return the wrong version first.
	s.scanner.catalog = newCatalog()
	s.scanner.catalog.Client.Transport = catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(`{"code":200,"result":{"songs":[
			{"id":1,"name":"Song","artists":[{"name":"Artist"}],"album":{"name":"Album"},"duration":242000},
			{"id":2,"name":"Song","artists":[{"name":"Artist"}],"album":{"name":"Album"},"duration":239000}]}}`))}, nil
	})
	candidates, err := s.scanner.searchTrackCandidates(context.Background(), "netease", track)
	if err != nil || len(candidates) != 2 || candidates[0].SourceID != "2" {
		t.Fatal("candidate correction order ignores duration", candidates, err)
	}
}

func TestLyricsPriorityValidationPersistenceAndFallback(t *testing.T) {
	s := testServer(t)
	token, h := loginToken(t, s), s.Handler()
	settings := s.store.SourceSettings()
	settings.Lyrics = "auto"
	settings.LyricsPriority = []string{"netease", "qq", "lrclib", "kugou"}
	settings.LyricsDisabled = []string{"netease", "lrclib", "kugou"}
	raw, _ := json.Marshal(settings)
	if w := request(h, "PUT", "/api/v1/sources", string(raw), token); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	// Old clients must not reset either list.
	if w := request(h, "PUT", "/api/v1/sources", `{"metadata":"qq","lyrics":"auto"}`, token); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	reopened, err := OpenStore(s.config.DataDir)
	if err != nil || !reflect.DeepEqual(reopened.SourceSettings().LyricsPriority, settings.LyricsPriority) || !reflect.DeepEqual(reopened.SourceSettings().LyricsDisabled, settings.LyricsDisabled) {
		t.Fatal("lyrics settings not retained", err)
	}
	for _, body := range []string{
		`{"metadata":"auto","lyrics":"auto","lyrics_priority":[]}`,
		`{"metadata":"auto","lyrics":"auto","lyrics_priority":["qq","qq","lrclib","kugou"]}`,
		`{"metadata":"auto","lyrics":"auto","lyrics_disabled":["itunes"]}`,
		`{"metadata":"auto","lyrics":"auto","lyrics_disabled":["qq","netease","kugou","lrclib"]}`,
	} {
		if w := request(h, "PUT", "/api/v1/sources", body, token); w.Code != 400 {
			t.Fatal("invalid lyric priority accepted", w.Body.String())
		}
	}
	s.scanner.catalog = mockCatalog(t, catalogFixtures)
	unexpected := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("disabled provider contacted") }))
	defer unexpected.Close()
	s.scanner.lyricProvider = &LyricsProvider{Client: unexpected.Client(), Endpoint: unexpected.URL}
	lyric, err := s.scanner.fetchLyrics(context.Background(), "auto", Track{Title: "Song", Artist: "Artist", Album: "Album", Duration: 239})
	if err != nil || lyric.Source != "qq" {
		t.Fatal("priority/disabled ignored", lyric, err)
	}
}

func TestScanWritesMissingTagsAndPreservesExistingLyrics(t *testing.T) {
	s := testServer(t)
	track := taggedAudioFixture(t, s, "flac", "", false)
	s.config.Scrape, s.scanner.config.Scrape = true, true
	if err := s.store.update(func(st *libraryState) error {
		st.Sources.Lyrics = "auto"
		st.Sources.LyricsPriority = []string{"netease", "qq", "lrclib", "kugou"}
		st.Sources.LyricsDisabled = []string{"qq", "lrclib", "kugou"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	s.scanner.catalog.Client.Transport = catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
		body := catalogFixtures[r.URL.Scheme+"://"+r.URL.Host+r.URL.Path]
		body = strings.ReplaceAll(body, "239000", "300")
		return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(body))}, nil
	})
	audio := streamDigest(t, track.Path, "0:a:0")
	if _, err := s.scanner.Start(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	s.scanner.Wait()
	tracks := s.store.Tracks()
	if len(tracks) != 1 || tracks[0].ID == track.ID || tracks[0].HasEmbeddedLyrics == nil || !*tracks[0].HasEmbeddedLyrics {
		t.Fatal("skipped indexed track did not receive lyrics", tracks, s.store.Jobs())
	}
	current, _ := s.store.Track(tracks[0].ID)
	if current.Path != track.Path || !reflect.DeepEqual(audio, streamDigest(t, current.Path, "0:a:0")) {
		t.Fatal("scan renamed/reencoded lyrics write", current.Path)
	}
	job := s.store.Jobs()[0]
	if len(job.Items) != 1 || job.Items[0].TrackID != current.ID || job.Items[0].Duration <= 0 {
		t.Fatal("task detail references stale ID/duration", job)
	}
	before := mustReadFile(t, current.Path)
	// Existing embedded lyrics are never replaced or fetched during rescans.
	s.scanner.catalog.Client.Transport = catalogRoundTripper(func(*http.Request) (*http.Response, error) {
		t.Error("existing tag lyrics triggered a provider fetch")
		return nil, errors.New("unexpected network request")
	})
	if _, err := s.scanner.Start(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	s.scanner.Wait()
	current, _ = s.store.Track(current.ID)
	if !reflect.DeepEqual(before, mustReadFile(t, current.Path)) {
		t.Fatal("rescan overwrote existing lyrics")
	}
}

func TestInterruptedLyricsReplacementRestoresIndexedBytes(t *testing.T) {
	s := testServer(t)
	track := taggedAudioFixture(t, s, "mp3", "", false)
	original := mustReadFile(t, track.Path)
	backup := lyricsBackup(track.Path, track.ID)
	if err := os.Link(track.Path, backup); err != nil {
		t.Fatal(err)
	}
	// Simulate a crash between replacing the audio and publishing its new index.
	staged := filepath.Join(s.config.LibraryDir, ".resona-staged-test")
	os.WriteFile(staged, []byte("incomplete transaction"), 0640)
	if err := os.Rename(staged, track.Path); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(s.config.DataDir)
	if err != nil || !reflect.DeepEqual(original, mustReadFile(t, track.Path)) || len(store.Tracks()) != 1 {
		t.Fatal("interrupted tag write did not restore original", err)
	}
}
