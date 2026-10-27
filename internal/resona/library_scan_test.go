package resona

import (
	"bytes"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestLibraryScanOnlyIndexesExistingMusic(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("requires ffmpeg")
	}
	s := testServer(t)
	track := taggedAudioFixture(t, s, "mp3", "", false)
	original, err := os.ReadFile(track.Path)
	if err != nil {
		t.Fatal(err)
	}
	for _, root := range []string{s.config.InboxDir, s.store.pluginInbox(s.config)} {
		if err := os.MkdirAll(root, 0750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "unimported.mp3"), original, 0640); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(s.config.LibraryDir, "Song-Artist.lrc"), []byte("[00:00.00]Keep sidecar only"), 0640); err != nil {
		t.Fatal(err)
	}
	if err := s.store.update(func(st *libraryState) error {
		delete(st.Tracks, track.ID)
		st.Tracks["missing"] = DiskTrack{Track: Track{ID: "missing"}, File: filepath.Join(s.config.LibraryDir, "removed.mp3")}
		st.Tracks["cloud"] = DiskTrack{Track: Track{ID: "cloud"}, Remote: &RemoteFile{Account: "42", FileID: "77"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	s.scanner.config.Scrape = true
	client := &http.Client{Transport: catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
		t.Error("index-only scan contacted a provider", r.URL.Host)
		return nil, errors.New("unexpected network request")
	})}
	s.scanner.scraper.Client, s.scanner.catalog.Client, s.scanner.lyricProvider.Client = client, client, client
	token := loginToken(t, s)
	if w := request(s.Handler(), "POST", "/api/v1/library/scan", "{}", ""); w.Code != 401 {
		t.Fatal("anonymous scan accepted")
	}
	w := request(s.Handler(), "POST", "/api/v1/library/scan", "{}", token)
	if w.Code != 202 {
		t.Fatal("scan rejected", w.Code, w.Body.String())
	}
	s.scanner.Wait()
	job := s.store.Jobs()[0]
	if !job.IndexOnly || job.State != "completed" || job.Processed != 1 || job.Imported != 1 {
		t.Fatal("scan included an import directory or failed", job)
	}
	indexed, ok := s.store.Track(track.ID)
	if !ok || indexed.Path != track.Path || indexed.Title != "Song" || indexed.HasEmbeddedLyrics == nil || *indexed.HasEmbeddedLyrics {
		t.Fatal("incorrect local index", indexed)
	}
	after, err := os.ReadFile(track.Path)
	if err != nil || !bytes.Equal(original, after) {
		t.Fatal("scan changed the audio or embedded sidecar lyrics", err)
	}
	if _, ok := s.store.Track("missing"); ok {
		t.Fatal("deleted local file remained indexed")
	}
	if _, ok := s.store.Track("cloud"); !ok {
		t.Fatal("local scan removed a cloud track")
	}
	if err := s.store.update(func(st *libraryState) error {
		disk := st.Tracks[track.ID]
		disk.Title, disk.Favorite, disk.MetadataLocked = "Corrected Song", true, true
		st.Tracks[track.ID] = disk
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.scanner.StartLibrary(t.Context()); err != nil {
		t.Fatal(err)
	}
	s.scanner.Wait()
	indexed, _ = s.store.Track(track.ID)
	if indexed.Title != "Corrected Song" || !indexed.Favorite || !indexed.MetadataLocked || s.store.Jobs()[0].Skipped != 1 {
		t.Fatal("rescan discarded saved corrections or favorites", indexed)
	}
	s.scanner.mu.Lock()
	s.scanner.active = true
	s.scanner.mu.Unlock()
	if _, err := s.scanner.StartLibrary(t.Context()); err == nil {
		t.Fatal("overlapping index scan accepted")
	}
	if _, err := s.scanner.Start(t.Context(), false); err == nil {
		t.Fatal("organizing overlapped index scan")
	}
}
