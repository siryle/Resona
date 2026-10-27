package resona

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestManagedFilesOperationsAndIndex(t *testing.T) {
	s := testServer(t)
	token := loginToken(t, s)
	path := filepath.Join(s.config.LibraryDir, "source.mp3")
	if err := os.WriteFile(path, []byte("original"), 0640); err != nil {
		t.Fatal(err)
	}
	if err := s.store.update(func(st *libraryState) error {
		st.Tracks["id"] = DiskTrack{Track: Track{ID: "id", Title: "Title", Favorite: true}, File: path}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"archive", "target"} {
		if err := os.Mkdir(filepath.Join(s.config.LibraryDir, name), 0750); err != nil {
			t.Fatal(err)
		}
	}
	h := s.Handler()
	op := func(action, root string, paths []string, targetRoot, target string, want int) {
		t.Helper()
		body, _ := json.Marshal(fileOperation{action, root, paths, targetRoot, target})
		w := request(h, "POST", "/api/v1/files/operations", string(body), token)
		if w.Code != want {
			t.Fatalf("%s: %d %s", action, w.Code, w.Body.String())
		}
	}
	w := request(h, "GET", "/api/v1/files?root=library", "", token)
	var result struct{ Items []fileEntry }
	if err := json.Unmarshal(w.Body.Bytes(), &result); w.Code != 200 || err != nil || len(result.Items) != 3 || result.Items[0].Type != "文件夹" {
		t.Fatal("list failed", w.Body.String(), err)
	}
	op("rename", "library", []string{"source.mp3"}, "", "renamed.mp3", 200)
	track, _ := s.store.Track("id")
	if track.Path != filepath.Join(s.config.LibraryDir, "renamed.mp3") || !track.Favorite {
		t.Fatal("rename lost index", track)
	}
	op("copy", "library", []string{"renamed.mp3"}, "library", "archive", 200)
	op("copy", "library", []string{"archive"}, "plugins", "", 200)
	requireMusicPermissions(t, s.store.pluginInbox(s.config))
	op("copy", "library", []string{"renamed.mp3"}, "library", "archive", 409)
	if string(mustReadFile(t, filepath.Join(s.config.LibraryDir, "archive/renamed.mp3"))) != "original" {
		t.Fatal("copy clobbered data")
	}
	requireMusicPermissions(t, filepath.Join(s.config.LibraryDir, "archive"))
	op("move", "library", []string{"renamed.mp3"}, "library", "target", 200)
	track, _ = s.store.Track("id")
	if !strings.HasSuffix(track.Path, "target/renamed.mp3") {
		t.Fatal("move did not update index", track)
	}
	// Cross-root moves keep bytes intact and remove entries outside the playable library.
	op("move", "library", []string{"target/renamed.mp3"}, "inbox", "", 200)
	requireMusicPermissions(t, filepath.Join(s.config.InboxDir, "renamed.mp3"))
	if _, ok := s.store.Track("id"); ok {
		t.Fatal("out-of-library file still playable")
	}
	if string(mustReadFile(t, filepath.Join(s.config.InboxDir, "renamed.mp3"))) != "original" {
		t.Fatal("cross-root move lost content")
	}
	op("copy", "library", []string{"archive"}, "inbox", "", 200)
	op("delete", "inbox", []string{"archive", "renamed.mp3"}, "", "", 200)
	op("delete", "library", []string{"archive"}, "", "", 200)
	if _, err := os.Stat(filepath.Join(s.config.InboxDir, "archive")); !os.IsNotExist(err) {
		t.Fatal("delete did not remove directory", err)
	}
	book, err := openLogBook(s.config.DataDir)
	if err != nil || len(book.entries) < 8 {
		t.Fatal("file actions not logged", err)
	}
}

func TestManagedFilesBoundariesBusyAndRollback(t *testing.T) {
	s := testServer(t)
	token, h := loginToken(t, s), s.Handler()
	for _, path := range []string{"/api/v1/files?root=library", "/api/v1/logs"} {
		if w := request(h, "GET", path, "", ""); w.Code != 401 {
			t.Fatal("admin page data exposed")
		}
	}
	if _, err := managedPath("bad\x00path"); err == nil {
		t.Fatal("NUL path accepted")
	}
	for _, path := range []string{"../data", "/etc", ".hidden"} {
		if _, err := managedPath(path); err != nil {
			t.Fatal("filesystem access was restricted", path, err)
		}
	}
	secret := filepath.Join(s.config.DataDir, "private")
	os.WriteFile(secret, []byte("private-secret"), 0600)
	os.Symlink(s.config.DataDir, filepath.Join(s.config.LibraryDir, "escape"))
	if w := request(h, "GET", "/api/v1/files?root=library&path=escape", "", token); w.Code != 200 {
		t.Fatal("filesystem navigation through directory link failed", w.Body.String())
	}
	w := request(h, "GET", "/api/v1/files?root=library", "", token)
	if !strings.Contains(w.Body.String(), `"name":"escape"`) || strings.Contains(w.Body.String(), "private-secret") {
		t.Fatal("directory link missing or content exposed", w.Body.String())
	}
	bad := `{"action":"delete","root":"library","paths":["/"]}`
	if w := request(h, "POST", "/api/v1/files/operations", bad, token); w.Code != 400 {
		t.Fatal("root deletion accepted")
	}
	r := httptest.NewRequest("POST", "/api/v1/files/operations", strings.NewReader(bad))
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Origin", "https://evil.example")
	recorder := httptest.NewRecorder()
	h.ServeHTTP(recorder, r)
	if recorder.Code != 403 {
		t.Fatal("cross origin mutation accepted")
	}
	path := filepath.Join(s.config.LibraryDir, "file.txt")
	os.WriteFile(path, []byte("keep"), 0640)
	body := `{"action":"rename","root":"library","paths":["file.txt"],"target":"renamed.txt"}`
	s.scanner.active = true
	if w := request(h, "POST", "/api/v1/files/operations", body, token); w.Code != 409 {
		t.Fatal("file mutation during scan")
	}
	s.scanner.active = false
	oldPath := s.store.path
	s.store.path = filepath.Join(s.config.DataDir, "missing", "index.json")
	w = request(h, "POST", "/api/v1/files/operations", body, token)
	s.store.path = oldPath
	if w.Code != 409 || string(mustReadFile(t, path)) != "keep" {
		t.Fatal("failed persistence did not roll back", w.Body.String())
	}
	if _, err := os.Stat(filepath.Join(s.config.LibraryDir, "renamed.txt")); !os.IsNotExist(err) {
		t.Fatal("rollback retained destination", err)
	}
	if _, err := os.Stat(s.fileJournal()); !os.IsNotExist(err) {
		t.Fatal("rollback left journal")
	}
}

func TestManagedFileRecovery(t *testing.T) {
	s := testServer(t)
	from := filepath.Join(s.config.LibraryDir, "old.mp3")
	to := filepath.Join(s.config.LibraryDir, "new.mp3")
	os.WriteFile(to, []byte("keep"), 0640)
	disk := DiskTrack{Track: Track{ID: "id", Favorite: true}, File: from}
	oldPath, _ := managedPath(from)
	newPath, _ := managedPath(to)
	pending := pendingFileOperation{Action: "rename", Root: "filesystem", Path: oldPath,
		TargetRoot: "filesystem", Destination: newPath, Hidden: newPath, Tracks: map[string]DiskTrack{"id": disk}}
	if err := atomicJSON(s.fileJournal(), pending); err != nil {
		t.Fatal(err)
	}
	moved := disk
	moved.File = to
	if err := s.store.update(func(st *libraryState) error { st.Tracks["id"] = moved; return nil }); err != nil {
		t.Fatal(err)
	}
	reopened, err := NewServer(context.Background(), s.config)
	if err != nil {
		t.Fatal(err)
	}
	track, ok := reopened.store.Track("id")
	if !ok || track.Path != from || !track.Favorite || string(mustReadFile(t, from)) != "keep" {
		t.Fatal("interrupted file operation was not restored", track)
	}
}

func TestManagedFilesOutsideShortcuts(t *testing.T) {
	s := testServer(t)
	token, h := loginToken(t, s), s.Handler()
	external := t.TempDir()
	original := filepath.Join(external, ".outside.txt")
	renamed := filepath.Join(external, "renamed.txt")
	if err := os.WriteFile(original, []byte("outside shortcut directories"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, operation := range []fileOperation{
		{Action: "rename", Root: "library", Paths: []string{original}, Target: renamed},
		{Action: "copy", Root: "inbox", Paths: []string{renamed}, TargetRoot: "library", Target: s.config.LibraryDir},
		{Action: "delete", Root: "plugins", Paths: []string{renamed}},
	} {
		body, err := json.Marshal(operation)
		if err != nil {
			t.Fatal(err)
		}
		w := request(h, "POST", "/api/v1/files/operations", string(body), token)
		if w.Code != 200 {
			t.Fatalf("%s outside shortcuts: %d %s", operation.Action, w.Code, w.Body.String())
		}
	}
	if _, err := os.Stat(renamed); !os.IsNotExist(err) {
		t.Fatal("external file was not deleted", err)
	}
	if got := string(mustReadFile(t, filepath.Join(s.config.LibraryDir, "renamed.txt"))); got != "outside shortcut directories" {
		t.Fatal("external copy lost content", got)
	}
}
