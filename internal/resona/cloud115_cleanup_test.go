package resona

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func seedCloudSTRM(t *testing.T, s *Server, fileID string) (string, string) {
	t.Helper()
	id := cloudTrackID("42", fileID)
	item := CloudItem{RemoteFile: RemoteFile{Account: "42", FileID: fileID},
		TrackID: id, Name: fileID + ".mp3", Path: fileID + ".mp3", State: "pending"}
	if err := s.cloud.writeSTRM(item); err != nil {
		t.Fatal(err)
	}
	path := s.cloud.strmPath(item)
	if err := s.store.update(func(st *libraryState) error {
		st.Cloud.Items[id] = item
		st.Cloud.ProbeQueue = append(st.Cloud.ProbeQueue, id)
		remote := item.RemoteFile
		st.Tracks[id] = DiskTrack{Track: Track{ID: id, Favorite: true}, File: path, Remote: &remote}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return id, path
}

func TestCloudManagedDeletionAndRename(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	id, path := seedCloudSTRM(t, s, "7")
	other, _ := seedCloudSTRM(t, s, "8")
	token := loginToken(t, s)
	operate := func(op fileOperation, want int) {
		t.Helper()
		body, _ := json.Marshal(op)
		w := request(s.Handler(), "POST", "/api/v1/files/operations", string(body), token)
		if w.Code != want {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	renamed := filepath.Join(filepath.Dir(path), "renamed.strm")
	operate(fileOperation{Action: "rename", Root: "filesystem", Paths: []string{path}, Target: renamed}, 200)
	if track, ok := s.store.Track(id); !ok || track.Path != renamed || !track.Favorite {
		t.Fatal("cloud rename lost the indexed track", track)
	}
	// Persistence failure must restore bytes, cloud items, and the FIFO queue.
	storePath := s.store.path
	s.store.path = filepath.Join(s.config.DataDir, "missing", "index.json")
	operate(fileOperation{Action: "delete", Root: "filesystem", Paths: []string{filepath.Dir(renamed)}}, 409)
	s.store.path = storePath
	if _, err := os.Stat(renamed); err != nil {
		t.Fatal("failed deletion did not restore STRM", err)
	}
	if state := s.cloud.snapshot(); len(state.Items) != 2 || !reflect.DeepEqual(state.ProbeQueue, []string{id, other}) {
		t.Fatal("failed deletion changed cloud state", state)
	}
	operate(fileOperation{Action: "delete", Root: "filesystem", Paths: []string{filepath.Dir(renamed)}}, 200)
	if _, ok := s.store.Track(id); ok {
		t.Fatal("deleted STRM remains in library")
	}
	if state := s.cloud.snapshot(); len(state.Items) != 1 || !reflect.DeepEqual(state.ProbeQueue, []string{other}) {
		t.Fatal("cloud item or queue was not cleaned", state)
	}
	reopened, err := OpenStore(s.config.DataDir)
	if err != nil || len(reopened.state.Cloud.Items) != 1 || len(reopened.state.Tracks) != 1 {
		t.Fatal("cloud deletion was not persisted", err)
	}
}

func TestCloudMissingSTRMReconciliation(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	id, path := seedCloudSTRM(t, s, "7")
	other, otherPath := seedCloudSTRM(t, s, "8")
	if err := os.RemoveAll(filepath.Dir(path)); err != nil {
		t.Fatal(err)
	}
	// A filesystem error other than absence must not discard the library entry.
	if err := os.Remove(otherPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Base(otherPath), otherPath); err != nil {
		t.Fatal(err)
	}
	if err := s.cloud.pruneMissingSTRMs(); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.store.Track(id); ok {
		t.Fatal("external deletion still indexed")
	}
	if _, ok := s.store.Track(other); !ok {
		t.Fatal("filesystem error discarded a track")
	}
	if queue := s.cloud.snapshot().ProbeQueue; !reflect.DeepEqual(queue, []string{other}) {
		t.Fatal("missing STRM still queued", queue)
	}
	if err := os.Remove(otherPath); err != nil {
		t.Fatal(err)
	}
	reopened, err := NewServer(context.Background(), s.config)
	if err != nil || len(reopened.cloud.snapshot().Items) != 0 || len(reopened.store.Tracks()) != 0 {
		t.Fatal("startup left orphaned cloud entries", err)
	}
}

func TestCloudDeletedSTRMCannotBeRecreatedByProbe(t *testing.T) {
	for _, duringProbe := range []bool{false, true} {
		t.Run(map[bool]string{false: "before", true: "during"}[duringProbe], func(t *testing.T) {
			s := testServer(t)
			seedCloud(t, s)
			id, path := seedCloudSTRM(t, s, "7")
			started, release, done := make(chan struct{}), make(chan struct{}), make(chan error, 1)
			s.cloud.probe = func(ctx context.Context, item CloudItem) (Track, error) {
				close(started)
				<-release
				return Track{Title: "Song", Artist: "Artist", Album: "Album"}, nil
			}
			if duringProbe {
				go func() { done <- s.cloud.probeNext(t.Context(), id) }()
				<-started
			}
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			if duringProbe {
				close(release)
				if err := <-done; err != nil {
					t.Fatal(err)
				}
			} else if err := s.cloud.probeNext(t.Context(), id); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatal("probe recreated deleted STRM", err)
			}
			if state := s.cloud.snapshot(); len(state.Items) != 0 || len(state.ProbeQueue) != 0 || len(s.store.Tracks()) != 0 {
				t.Fatal("probe republished deleted track", state)
			}
		})
	}
}

func TestCloudFileRecoveryRestoresItemsAndQueue(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	id, path := seedCloudSTRM(t, s, "7")
	other, _ := seedCloudSTRM(t, s, "8")
	hidden := path + ".staged"
	oldPath, _ := managedPath(path)
	hiddenPath, _ := managedPath(hidden)
	pending := pendingFileOperation{Action: "delete", Root: "filesystem", Path: oldPath, Hidden: hiddenPath,
		Tracks:     map[string]DiskTrack{id: s.store.state.Tracks[id]},
		CloudItems: map[string]CloudItem{id: s.cloud.snapshot().Items[id]}, ProbeQueue: []string{id, other}}
	if err := atomicJSON(s.fileJournal(), pending); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(path, hidden); err != nil {
		t.Fatal(err)
	}
	if err := s.store.update(func(st *libraryState) error {
		removeCloudTracks(st, map[string]bool{id: true})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	reopened, err := NewServer(context.Background(), s.config)
	if err != nil {
		t.Fatal(err)
	}
	if state := reopened.cloud.snapshot(); len(state.Items) != 2 || !reflect.DeepEqual(state.ProbeQueue, []string{id, other}) {
		t.Fatal("restart did not restore cloud items and queue", state)
	}
	if disk, ok := reopened.store.Track(id); !ok || !disk.Favorite || disk.Path != path {
		t.Fatal("restart lost cloud track", disk)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("restart did not restore STRM", err)
	}
}

func TestCloudSTRMUsesMainServiceAddress(t *testing.T) {
	for _, base := range []string{"http://resona.lan:35280", "https://music.example.com"} {
		t.Run(base, func(t *testing.T) {
			s := testServer(t)
			seedCloud(t, s)
			token := loginToken(t, s)
			r := httptest.NewRequest("PUT", base+"/api/v1/cloud115", strings.NewReader(`{"root_id":"0","enabled":true}`))
			r.Header.Set("Content-Type", "application/json")
			r.Header.Set("Authorization", "Bearer "+token)
			w := httptest.NewRecorder()
			s.Handler().ServeHTTP(w, r)
			if w.Code != 200 || s.cloud.summary().Settings.BaseURL != base {
				t.Fatal("did not default to main service address", w.Code, w.Body.String())
			}
			id, path := seedCloudSTRM(t, s, "7")
			if content := string(mustReadFile(t, path)); content != base+"/api/v1/tracks/"+id+"/stream\n" {
				t.Fatal("STRM uses a separate service address", content)
			}
		})
	}
}
