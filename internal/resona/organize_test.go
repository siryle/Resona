package resona

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func requireMusicPermissions(t *testing.T, root string) {
	t.Helper()
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Mode().Perm() != 0777 {
			t.Errorf("%s has permissions %o, want 777", path, info.Mode().Perm())
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestScanSkipsSameTitleAndPerformerAcrossEncodingsAndAlbums(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("requires ffmpeg")
	}
	s := testServer(t)
	original := taggedAudioFixture(t, s, "mp3", "[00:00]Embedded", false)
	for _, performer := range []string{"Artist", "Other Artist"} {
		path := filepath.Join(s.config.InboxDir, performer+".flac")
		if out, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=880:duration=0.3",
			"-metadata", "title=Song", "-metadata", "artist="+performer, "-metadata", "album=Another Album",
			"-metadata", "lyrics=[00:00]Embedded", path).CombinedOutput(); err != nil {
			t.Fatal(err, string(out))
		}
	}
	// The same identity in the other library must not prevent a local import.
	if err := s.store.update(func(st *libraryState) error {
		remote := RemoteFile{Account: "42"}
		st.Tracks["cloud"] = DiskTrack{Track: Track{ID: "cloud", Title: "Song", Artist: "Other Artist"}, Remote: &remote}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for _, rescrape := range []bool{false, true} {
		if _, err := s.scanner.Start(context.Background(), rescrape); err != nil {
			t.Fatal(err)
		}
		s.scanner.Wait()
		if len(s.store.Tracks()) != 3 {
			t.Fatal("same performer duplicate imported, or cross-library/different performer removed", s.store.Tracks())
		}
		found := false
		for _, item := range s.store.Jobs()[0].Items {
			if item.Filename == "Artist.flac" {
				found = item.State == "skipped" && item.TrackID == original.ID && strings.Contains(item.Message, "同名同歌手")
			}
		}
		if !found {
			t.Fatal("duplicate skip detail missing", s.store.Jobs()[0])
		}
		if _, err := os.Stat(filepath.Join(s.config.InboxDir, "Artist.flac")); err != nil {
			t.Fatal("duplicate source removed", err)
		}
	}
	requireMusicPermissions(t, filepath.Join(s.config.LibraryDir, "Other Artist"))
}

func TestCorrectionMovesLyricsAndRollsBackFailures(t *testing.T) {
	s := testServer(t)
	track := addTestTrack(t, s)
	sidecar := strings.TrimSuffix(track.Path, ".mp3") + ".lrc"
	if err := os.WriteFile(sidecar, []byte("[00:01]Original"), 0600); err != nil {
		t.Fatal(err)
	}
	metadata := metadataOf(track)
	metadata.Title, metadata.Artist, metadata.AlbumArtist, metadata.Album = "New", "New Artist", "New Artist", "New Album"
	body, _ := json.Marshal(metadata)
	token := loginToken(t, s)
	path := "/api/v1/tracks/" + track.ID + "/metadata"
	// A conflicting sidecar fails before publishing the new index or removing source files.
	destDir := filepath.Join(s.config.LibraryDir, "New Artist", "New Album")
	os.MkdirAll(destDir, 0750)
	dest := filepath.Join(destDir, "New-New Artist.mp3")
	os.WriteFile(strings.TrimSuffix(dest, ".mp3")+".lrc", []byte("Conflicting"), 0600)
	if w := request(s.Handler(), "PUT", path, string(body), token); w.Code != 500 {
		t.Fatal("conflicting sidecar accepted", w.Code, w.Body.String())
	}
	current, _ := s.store.Track(track.ID)
	if current.Path != track.Path || current.Title != track.Title {
		t.Fatal("failed move changed index", current)
	}
	if _, err := os.Stat(dest); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("failed move left staged audio", err)
	}
	os.Remove(strings.TrimSuffix(dest, ".mp3") + ".lrc")
	if w := request(s.Handler(), "PUT", path, string(body), token); w.Code != 200 {
		t.Fatal("correction failed", w.Code, w.Body.String())
	}
	current, _ = s.store.Track(track.ID)
	if current.Path != dest {
		t.Fatal("correction did not organize", current)
	}
	data, err := os.ReadFile(strings.TrimSuffix(dest, ".mp3") + ".lrc")
	if err != nil || string(data) != "[00:01]Original" {
		t.Fatal("sidecar did not follow correction", err)
	}
	if _, err := os.Stat(sidecar); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("old sidecar remains", err)
	}
	requireMusicPermissions(t, s.config.LibraryDir)
	// Persistence failure must roll back all staged files while retaining the indexed original.
	metadata.Title = "Failed"
	body, _ = json.Marshal(metadata)
	stateFile := s.store.path
	s.store.path = filepath.Join(s.config.DataDir, "missing", "state.json")
	w := request(s.Handler(), "PUT", path, string(body), token)
	s.store.path = stateFile
	if w.Code != 500 {
		t.Fatal("persistence failure accepted", w.Code)
	}
	current, _ = s.store.Track(track.ID)
	if current.Path != dest || current.Title != "New" {
		t.Fatal("persistence failure changed original index", current)
	}
	if _, err := os.Stat(filepath.Join(destDir, "Failed-New Artist.mp3")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("persistence failure left staged destination")
	}
}

func TestCloudDuplicateSkipAndCorrectionOnlyMovesLocalReferences(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	for i, fileID := range []string{"7", "8"} {
		id := cloudTrackID("42", fileID)
		item := CloudItem{RemoteFile: RemoteFile{Account: "42", FileID: fileID, PickCode: "pickcode", SHA1: strings.Repeat("a", 40)},
			Name: fileID + ".flac", TrackID: id, State: "pending", UpdatedAt: time.Now()}
		if err := s.store.update(func(st *libraryState) error { st.Cloud.Items[id] = item; return nil }); err != nil {
			t.Fatal(err)
		}
		if err := s.cloud.writeSTRM(item); err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			item.LRC = &RemoteFile{FileID: "9"}
			if err := os.WriteFile(strings.TrimSuffix(s.cloud.strmPath(item), ".strm")+".lrc", []byte("[00:00.00]Lyrics"), 0600); err != nil {
				t.Fatal(err)
			}
		}
		if err := s.cloud.publish(item, Track{Title: "Song", Artist: "Artist", Album: "Album", Format: "flac"}); err != nil {
			t.Fatal(err)
		}
		want := "ready"
		if i == 1 {
			want = "skipped"
		}
		if got := s.cloud.snapshot().Items[id].State; got != want {
			t.Fatal("wrong cloud duplicate status", got, want)
		}
	}
	id := cloudTrackID("42", "7")
	before, _ := s.store.Track(id)
	metadata := metadataOf(before)
	metadata.Title, metadata.Artist, metadata.AlbumArtist, metadata.Album = "Corrected", "New Artist", "New Artist", "New Album"
	body, _ := json.Marshal(metadata)
	token := loginToken(t, s)
	w := request(s.Handler(), "PUT", "/api/v1/tracks/"+id+"/metadata", string(body), token)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	after, _ := s.store.Track(id)
	if !strings.Contains(after.Path, filepath.Join("New Artist", "New Album", id)) || after.Path == before.Path || after.Format != "flac" {
		t.Fatal("cloud reference not organized correctly", after)
	}
	contents, err := os.ReadFile(after.Path)
	if err != nil || !strings.Contains(string(contents), "/tracks/"+id+"/stream") || s.cloud.snapshot().Items[id].FileID != "7" {
		t.Fatal("cloud correction altered remote identity", string(contents), err)
	}
	if err := s.cloud.writeSTRM(s.cloud.snapshot().Items[id]); err != nil {
		t.Fatal(err)
	}
	if s.cloud.strmPath(s.cloud.snapshot().Items[id]) != after.Path {
		t.Fatal("sync reverted corrected STRM path")
	}
	requireMusicPermissions(t, filepath.Join(s.config.DataDir, "cloud115", "strm"))
}

func TestMusicDirectoryRejectsEscapingSymlink(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "Artist")); err != nil {
		t.Fatal(err)
	}
	if _, err := musicDirectory(root, filepath.Join(root, "Artist", "Album")); err == nil {
		t.Fatal("escaped directory accepted")
	}
	if _, err := os.Stat(filepath.Join(outside, "Album")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("directory created outside root")
	}
}

func TestCorrectionSkipsSameLibraryDuplicateAndBusyScan(t *testing.T) {
	s := testServer(t)
	track := addTestTrack(t, s)
	if err := s.store.update(func(st *libraryState) error {
		st.Tracks["existing"] = DiskTrack{Track: Track{ID: "existing", Title: "Other", Artist: "Artist", Album: "Other Album"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	body := `{"title":" other ","artist":"ARTIST","album":"Different Album"}`
	token := loginToken(t, s)
	path := "/api/v1/tracks/" + track.ID + "/metadata"
	if w := request(s.Handler(), "PUT", path, body, token); w.Code != 409 {
		t.Fatal("duplicate correction accepted", w.Code, w.Body.String())
	}
	current, _ := s.store.Track(track.ID)
	if current.Path != track.Path || current.Title != track.Title {
		t.Fatal("duplicate correction changed original", current)
	}
	s.scanner.mu.Lock()
	s.scanner.active = true
	s.scanner.mu.Unlock()
	w := request(s.Handler(), "PUT", path, body, token)
	s.scanner.mu.Lock()
	s.scanner.active = false
	s.scanner.mu.Unlock()
	if w.Code != 409 {
		t.Fatal("correction accepted during scan", w.Code)
	}
}
