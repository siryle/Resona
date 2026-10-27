package resona

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSTRMRegenerationPreservesSharedDirectory(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	ids := queueCloudItems(t, s, "A", "B")
	if err := s.cloud.generateSTRMs(context.Background()); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(s.config.DataDir, "cloud115", "strm", "shared")
	if err := os.MkdirAll(dir, 0777); err != nil {
		t.Fatal(err)
	}
	var original, paths []string
	for _, id := range ids {
		track, _ := s.store.Track(id)
		original = append(original, track.Path)
		paths = append(paths, filepath.Join(dir, filepath.Base(track.Path)))
	}
	body, _ := json.Marshal(fileOperation{Action: "move", Root: "strm", Paths: original, TargetRoot: "strm", Target: dir})
	response := request(s.Handler(), "POST", "/api/v1/files/operations", string(body), loginToken(t, s))
	if response.Code != 200 {
		t.Fatalf("move: %d %s", response.Code, response.Body.String())
	}
	for i, path := range paths {
		if err := os.WriteFile(strings.TrimSuffix(path, ".strm")+".lrc", []byte(fmt.Sprintf("lyrics-%d", i)), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.store.update(func(st *libraryState) error {
		st.Cloud.Settings.BaseURL = "http://new.example"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.cloud.generateSTRMs(context.Background()); err != nil {
		t.Fatal(err)
	}
	for i, path := range paths {
		data, err := os.ReadFile(strings.TrimSuffix(path, ".strm") + ".lrc")
		if err != nil || string(data) != fmt.Sprintf("lyrics-%d", i) {
			t.Fatalf("neighbor lyrics overwritten: %s %v", data, err)
		}
	}
	present := 0
	for _, path := range paths {
		if _, err := os.Stat(path); err == nil {
			present++
		}
	}
	t.Logf("generated=%d, indexed=%d, files remaining=%d", len(ids), len(s.store.Tracks()), present)
	if present != 2 {
		t.Fatalf("regeneration deleted another indexed STRM: expected 2 files, got %d", present)
	}
}

func TestMusicBrainzEnrichmentMatchesKnownAlbum(t *testing.T) {
	fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"recordings":[{"id":"wrong-recording","title":"Song","score":100,"length":200000,"artist-credit":[{"name":"Artist"}],"releases":[{"id":"wrong-release","title":"Other Album","status":"Official","date":"2000-01-01"}]},{"id":"right-recording","title":"Song","score":100,"length":200000,"artist-credit":[{"name":"Artist"}],"releases":[{"id":"right-release","title":"Known Album","status":"Official","date":"2020-01-01"}]}]}`)
	}))
	defer fixture.Close()
	server := testServer(t)
	server.scanner.scraper = &Scraper{Client: fixture.Client(), Endpoint: fixture.URL}
	track := Track{Title: "Song", Artist: "Artist", Album: "Known Album", Duration: 200}
	if err := server.scanner.enrich(context.Background(), &track, "musicbrainz"); err != nil {
		t.Fatal(err)
	}
	t.Logf("MBID=%s release=%s year=%s album=%s", track.MBID, track.ReleaseID, track.Year, track.Album)
	if track.MBID != "right-recording" || track.ReleaseID != "right-release" {
		t.Fatalf("known album was ignored: %+v", track)
	}
}
