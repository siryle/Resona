package resona

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCloudLocalScanNeverGeneratesOrRequests115(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("local STRM scan requested 115", r.URL.Path)
		w.WriteHeader(500)
	}))
	defer api.Close()
	s.cloud.apiURL, s.cloud.webURL = api.URL, api.URL
	moved, oldPath := seedCloudSTRM(t, s, "7")
	missing, missingPath := seedCloudSTRM(t, s, "8")
	restore, restorePath := seedCloudSTRM(t, s, "9")
	newPath := filepath.Join(filepath.Dir(oldPath), "renamed.strm")
	if err := os.Rename(oldPath, newPath); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(filepath.Dir(newPath), "zz-copy.strm"), mustReadFile(t, newPath), 0777); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(missingPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(restorePath, filepath.Join(filepath.Dir(oldPath), "symlink.strm")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(filepath.Dir(oldPath), "unknown.strm"), []byte("https://outside.invalid/song.mp3"), 0777); err != nil {
		t.Fatal(err)
	}
	if err := s.store.update(func(st *libraryState) error {
		disk := st.Tracks[moved]
		disk.Title, disk.Artist, disk.Album, disk.Duration = "Edited title", "Artist", "Album", 42
		disk.MetadataSource, disk.MetadataLocked = "manual", true
		st.Tracks[moved] = disk
		st.Tracks["local"] = DiskTrack{Track: Track{ID: "local", Title: "Local"}}
		delete(st.Tracks, restore)
		st.Cloud.Cookie, st.Cloud.Settings.Enabled = "", false
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	token := loginToken(t, s)
	if w := request(s.Handler(), "POST", "/api/v1/cloud115/scan", "{}", ""); w.Code != 401 {
		t.Fatal("anonymous scan accepted", w.Code)
	}
	w := request(s.Handler(), "POST", "/api/v1/cloud115/scan", "{}", token)
	var started Job
	if w.Code != 202 || json.Unmarshal(w.Body.Bytes(), &started) != nil || started.Library != "cloud" {
		t.Fatal("scan not launched as background task", w.Code, w.Body.String())
	}
	s.cloud.wg.Wait()
	job, ok := s.store.Job(started.ID)
	if !ok || job.State != "completed" || job.Imported != 2 || job.Skipped != 3 || len(job.Items) != 2 {
		t.Fatalf("scan job incorrect: %+v", job)
	}
	track, ok := s.store.Track(moved)
	if !ok || track.Path != newPath || track.Title != "Edited title" || !track.Favorite ||
		!track.MetadataLocked || track.Duration != 42 || !track.Unavailable {
		t.Fatalf("local scan lost existing metadata: %+v", track)
	}
	if _, ok := s.store.Track(restore); !ok {
		t.Fatal("local STRM with stored remote identity was not indexed")
	}
	if _, ok := s.store.Track(missing); ok {
		t.Fatal("deleted STRM retained in library")
	}
	if _, err := os.Stat(missingPath); !os.IsNotExist(err) {
		t.Fatal("local scan regenerated a deleted STRM", err)
	}
	if _, ok := s.store.Track("local"); !ok {
		t.Fatal("local scan changed local audio library")
	}
	if state := s.cloud.snapshot(); len(state.Items) != 2 || !state.LastSync.IsZero() ||
		len(state.ProbeQueue) != 2 || s.cloud.probeBusy {
		t.Fatal("scan changed remote sync time or launched a probe", state)
	}
	details := request(s.Handler(), "GET", "/api/v1/jobs/"+started.ID, "", token)
	if details.Code != 200 || !strings.Contains(details.Body.String(), "已读取本地 STRM") {
		t.Fatal("scan details missing", details.Code, details.Body.String())
	}
}

func TestCloudLocalScanCancellationPreservesIndex(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	id, path := seedCloudSTRM(t, s, "7")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if err := s.cloud.scanSTRMs(ctx, &Job{}); err != context.Canceled {
		t.Fatal("cancelled scan did not stop", err)
	}
	if _, ok := s.store.Track(id); !ok {
		t.Fatal("incomplete scan discarded existing entry")
	}
	s.cloud.mu.Lock()
	s.cloud.busy = true
	s.cloud.mu.Unlock()
	w := request(s.Handler(), "POST", "/api/v1/cloud115/scan", "{}", loginToken(t, s))
	if w.Code != 409 {
		t.Fatal("scan raced a generation task", w.Code)
	}
}
