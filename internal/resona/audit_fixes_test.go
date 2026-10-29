package resona

import (
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestStreamConfinesConcurrentSymlinkReplacement(t *testing.T) {
	s := testServer(t)
	path := filepath.Join(s.config.LibraryDir, "song.mp3")
	stable := filepath.Join(s.config.LibraryDir, "original.mp3")
	outside := filepath.Join(s.config.DataDir, "private.txt")
	for name, contents := range map[string]string{stable: "public audio", outside: "PRIVATE_SENTINEL"} {
		if err := os.WriteFile(name, []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink("original.mp3", path); err != nil {
		t.Fatal(err)
	}
	if err := s.store.update(func(st *libraryState) error {
		st.Tracks["song"] = DiskTrack{Track: Track{ID: "song", Format: "mp3"}, File: path}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	stream := func() *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "/stream", nil)
		r.SetPathValue("id", "song")
		w := httptest.NewRecorder()
		s.stream(w, r)
		return w
	}
	if w := stream(); w.Code != 200 || w.Body.String() != "public audio" {
		t.Fatal("in-library symlink no longer plays", w.Code, w.Body.String())
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(stable, path); err != nil {
		t.Fatal(err)
	}
	if w := stream(); w.Code != 200 || w.Body.String() != "public audio" {
		t.Fatal("absolute in-library symlink no longer plays", w.Code, w.Body.String())
	}
	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		stage := filepath.Join(s.config.LibraryDir, ".swap")
		defer os.Remove(stage)
		for {
			select {
			case <-stop:
				return
			default:
			}
			if os.Symlink(outside, stage) == nil {
				os.Rename(stage, path)
			}
			if os.Link(stable, stage) == nil {
				os.Rename(stage, path)
			}
		}
	}()
	defer func() { close(stop); wg.Wait() }()
	for range 3000 {
		w := stream()
		if w.Code == 200 && w.Body.String() != "public audio" {
			t.Fatal("stream escaped library during replacement", w.Body.String())
		}
		if w.Code != 200 && w.Code != 404 {
			t.Fatal("unexpected stream status", w.Code)
		}
	}
}

func TestCloudPublishPreservesLatestUserChanges(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	id := cloudTrackID("42", "7")
	item := CloudItem{RemoteFile: RemoteFile{Account: "42", FileID: "7", PickCode: "pc",
		SHA1: strings.Repeat("a", 40)}, TrackID: id, Name: "song.flac", State: "pending"}
	if err := s.store.update(func(st *libraryState) error {
		st.Cloud.Items[id] = item
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.cloud.writeSTRM(item); err != nil {
		t.Fatal(err)
	}
	track := Track{Title: "Song", Artist: "Artist", Album: "Album", Format: "flac"}
	if err := s.cloud.publish(item, track); err != nil {
		t.Fatal(err)
	}
	track.AlbumArtist = "New Artist"
	s.store.writeMu.Lock()
	done := make(chan error, 1)
	go func() { done <- s.cloud.publish(item, track) }()
	destination := filepath.Join(s.config.DataDir, "cloud115", "strm", "New Artist", "Album", id, "Song-Artist.strm")
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(destination); err == nil {
			break
		}
		if time.Now().After(deadline) {
			s.store.writeMu.Unlock()
			<-done
			t.Fatal("publish did not stage STRM")
		}
		time.Sleep(time.Millisecond)
	}
	// Commit a user write after publish has read its snapshot, before it can
	// acquire the writer lock. This avoids relying on goroutine lock ordering.
	s.store.mu.Lock()
	next := cloneLibrary(s.store.state)
	latest := next.Tracks[id]
	latest.Favorite = true
	latest.Lyrics = &SavedLyrics{Text: "[00:01]Latest lyrics", Source: "manual"}
	next.Tracks[id] = latest
	err := s.store.persist(s.store.state, next)
	if err == nil {
		s.store.state = next
	}
	s.store.mu.Unlock()
	s.store.writeMu.Unlock()
	if publishErr := <-done; publishErr != nil || err != nil {
		t.Fatal(publishErr, err)
	}
	s.store.mu.RLock()
	saved := s.store.state.Tracks[id]
	s.store.mu.RUnlock()
	if !saved.Favorite || !reflect.DeepEqual(saved.Lyrics, latest.Lyrics) || saved.AlbumArtist != "New Artist" {
		t.Fatal("probe overwrote a committed user change", saved)
	}
}

func TestTrustedProxyClientAddresses(t *testing.T) {
	trusted, err := parseTrustedProxies("127.0.0.1,10.0.0.0/8,::1")
	if err != nil {
		t.Fatal(err)
	}
	a := &Auth{trusted: trusted}
	for _, tc := range []struct{ peer, forwarded, expected string }{
		{"192.0.2.1:42", "203.0.113.1", "192.0.2.1"},
		{"127.0.0.1:42", "203.0.113.1", "203.0.113.1"},
		{"127.0.0.1:42", "203.0.113.2", "203.0.113.2"},
		{"127.0.0.1:42", "198.51.100.1, 203.0.113.1", "203.0.113.1"},
		{"127.0.0.1:42", "203.0.113.1, 10.1.2.3", "203.0.113.1"},
		{"[::ffff:127.0.0.1]:42", "203.0.113.1", "203.0.113.1"},
		{"[::1]:42", "", "::1"},
		{"[::1]:42", "203.0.113.1, invalid", "::1"},
	} {
		r := httptest.NewRequest("POST", "/login", nil)
		r.RemoteAddr = tc.peer
		r.Header.Set("X-Forwarded-For", tc.forwarded)
		if got := a.clientAddress(r); got != tc.expected {
			t.Errorf("%s via %s: got %s, want %s", tc.forwarded, tc.peer, got, tc.expected)
		}
	}
	for _, value := range []string{"localhost", "10.1.2.3/33", "127.0.0.1,", "0.0.0.0/0,invalid"} {
		t.Setenv("TRUSTED_PROXIES", value)
		if _, err := ConfigFromEnv(); err == nil {
			t.Fatalf("accepted invalid TRUSTED_PROXIES %q", value)
		}
	}
}

func TestTrustedProxyLoginThrottleIsolation(t *testing.T) {
	s := testServer(t)
	s.auth.trusted, _ = parseTrustedProxies("127.0.0.1")
	r := httptest.NewRequest("POST", "/login", nil)
	r.RemoteAddr = "127.0.0.1:42"
	r.Header.Set("X-Forwarded-For", "203.0.113.1")
	s.auth.attempts["203.0.113.1"] = attempt{Count: 8, Since: time.Now()}
	if _, err := s.auth.login(r, "admin", "wrong"); !errors.Is(err, errThrottled) {
		t.Fatal("blocked client bypassed throttle", err)
	}
	r.Header.Set("X-Forwarded-For", "203.0.113.2")
	if _, err := s.auth.login(r, "admin", "a-test-password-123"); err != nil {
		t.Fatal("proxy aggregated independent clients", err)
	}
	r.RemoteAddr = "192.0.2.1:42"
	s.auth.attempts["192.0.2.1"] = attempt{Count: 8, Since: time.Now()}
	if _, err := s.auth.login(r, "admin", "a-test-password-123"); !errors.Is(err, errThrottled) {
		t.Fatal("untrusted forwarding bypassed throttle", err)
	}
}

func TestJobProgressPersistsIncrementallyAndRecovers(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { store.Close() }()
	job := Job{ID: "scan", State: "running", Errors: []string{}, Items: []JobItem{{Filename: "one", State: "processing"}}}
	if err := store.putJob(job); err != nil {
		t.Fatal(err)
	}
	job.Items[0].State = "imported"
	job.Items = append(job.Items, JobItem{Filename: "two", State: "processing"})
	job.Processed = 2
	if err := store.putJobProgress(job, 0); err != nil {
		t.Fatal(err)
	}
	job.Items[0].Message = "caller mutation"
	saved, _ := store.Job(job.ID)
	if saved.Items[0].Message != "" {
		t.Fatal("progress retained caller-owned items")
	}
	if _, err := store.db.Exec("CREATE TRIGGER reject_progress BEFORE UPDATE ON job_items BEGIN SELECT RAISE(ABORT,'disk failure'); END"); err != nil {
		t.Fatal(err)
	}
	job.Items[1].State = "imported"
	if err := store.putJobProgress(job, 1); err == nil {
		t.Fatal("accepted failed progress write")
	}
	saved, _ = store.Job(job.ID)
	if saved.Items[1].State != "processing" {
		t.Fatal("failed progress changed memory")
	}
	if _, err := store.db.Exec("DROP TRIGGER reject_progress"); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	saved, _ = store.Job(job.ID)
	if saved.State != "interrupted" || saved.Items[0].State != "imported" || saved.Items[1].State != "interrupted" {
		t.Fatal("progress recovery lost committed details", saved)
	}
}

func TestJobProgressAllocationGrowth(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	job := Job{ID: "scan", State: "running"}
	if err := store.putJob(job); err != nil {
		t.Fatal(err)
	}
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	for i := range 4000 {
		job.Items = append(job.Items, JobItem{Filename: "song.mp3", State: "imported"})
		job.Processed++
		if err := store.putJobProgress(job, i); err != nil {
			t.Fatal(err)
		}
	}
	runtime.ReadMemStats(&after)
	allocated := after.TotalAlloc - before.TotalAlloc
	t.Logf("4000 progress updates allocated %.1f MiB", float64(allocated)/(1<<20))
	if allocated > 64<<20 {
		t.Fatal("scan progress allocation is no longer bounded per item", allocated)
	}
}
