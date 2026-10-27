package resona

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func waitCloud(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for cloud task")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func queueCloudItems(t *testing.T, s *Server, names ...string) []string {
	t.Helper()
	var ids []string
	if err := s.store.update(func(st *libraryState) error {
		for _, name := range names {
			id := cloudTrackID("42", name)
			st.Cloud.Items[id] = CloudItem{RemoteFile: RemoteFile{Account: "42", FileID: name},
				TrackID: id, Name: name + ".mp3", Path: name + ".mp3", State: "pending"}
			ids = append(ids, id)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return ids
}

func TestCloudQueueSerialDeduplicatedAndGenerationIndependent(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	files := []any{treeFile("1", "0", "A.mp3"), treeFile("2", "0", "B.mp3"), treeFile("3", "0", "C.mp3")}
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jsonResponse(w, 200, map[string]any{"state": true, "cid": "0",
			"path": []any{map[string]any{"cid": "0"}}, "count": len(files), "data": files})
	}))
	defer api.Close()
	s.cloud.webURL = api.URL
	if err := s.cloud.generate(t.Context()); err != nil {
		t.Fatal(err)
	}
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	defer func() { once.Do(func() { close(release) }); s.cloud.wg.Wait() }()
	var order []string
	var orderMu sync.Mutex
	s.cloud.probe = func(ctx context.Context, item CloudItem) (Track, error) {
		orderMu.Lock()
		order = append(order, item.Name)
		orderMu.Unlock()
		if item.Name == "A.mp3" {
			close(started)
			<-release
		}
		if item.Name == "B.mp3" {
			previous, ok := s.store.Track(cloudTrackID("42", "1"))
			if !ok || previous.Duration != 1 || s.cloud.snapshot().Items[previous.ID].State != "ready" {
				t.Error("next probe started before the previous result was published")
			}
			return Track{}, errors.New("bad audio")
		}
		return Track{Title: item.Name, Artist: "Artist", AlbumArtist: "Artist", Album: "Album", Duration: 1}, nil
	}
	if err := s.cloud.start("probe", ""); err != nil {
		t.Fatal(err)
	}
	<-started
	token := loginToken(t, s)
	status := request(s.Handler(), "GET", "/api/v1/cloud115", "", token).Body.String()
	if !strings.Contains(status, `"probe_queued":2`) || !strings.Contains(status, `"sync_busy":false`) {
		t.Fatal("independent queue status missing", status)
	}
	var requests sync.WaitGroup
	for range 12 {
		requests.Add(1)
		go func() {
			defer requests.Done()
			if err := s.cloud.start("retry", cloudTrackID("42", "1")); err != nil {
				t.Error(err)
			}
		}()
	}
	requests.Wait()
	if len(s.cloud.snapshot().ProbeQueue) != 3 {
		t.Fatal("duplicate queue entries")
	}
	// A blocked remote probe must not hold up directory generation or library refresh.
	if err := s.cloud.start("sync", ""); err != nil {
		t.Fatal(err)
	}
	waitCloud(t, func() bool {
		s.cloud.mu.Lock()
		defer s.cloud.mu.Unlock()
		return !s.cloud.busy
	})
	if len(s.store.Tracks()) != 3 {
		t.Fatal("generation did not publish basic entries")
	}
	orderMu.Lock()
	if !reflect.DeepEqual(order, []string{"A.mp3"}) {
		t.Error("another probe started before the first finished", order)
	}
	orderMu.Unlock()
	once.Do(func() { close(release) })
	s.cloud.wg.Wait()
	if !reflect.DeepEqual(order, []string{"A.mp3", "B.mp3", "C.mp3"}) {
		t.Fatal("queue is not FIFO or stopped after a failure", order)
	}
	state := s.cloud.snapshot()
	if len(state.ProbeQueue) != 0 || state.Items[cloudTrackID("42", "2")].State != "failed" ||
		state.Items[cloudTrackID("42", "3")].State != "ready" {
		t.Fatal("queue completion state incorrect", state)
	}
	logs := request(s.Handler(), "GET", "/api/v1/logs?category=probe", "", token)
	for _, message := range []string{"预探测任务开始", "开始预探测歌曲", "歌曲预探测完成", "歌曲预探测失败", "预探测任务结束"} {
		if logs.Code != 200 || !strings.Contains(logs.Body.String(), message) {
			t.Fatal("probe lifecycle log missing", message, logs.Body.String())
		}
	}
	if !strings.Contains(logs.Body.String(), "paused=false") {
		t.Fatal("a completed queue was logged as paused", logs.Body.String())
	}
}

func TestCloudQueuePausesOnDownloadRestriction(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	ids := queueCloudItems(t, s, "A", "B", "C")
	calls := 0
	s.cloud.probe = func(context.Context, CloudItem) (Track, error) {
		calls++
		return Track{}, &cloudHTTPError{Status: 405, Path: "/android/2.0/ufile/download"}
	}
	if err := s.cloud.start("probe", ""); err != nil {
		t.Fatal(err)
	}
	s.cloud.wg.Wait()
	st := s.cloud.snapshot()
	if calls != 1 || len(st.ProbeQueue) != 3 || st.Items[ids[0]].State != "failed" ||
		st.Items[ids[1]].State != "pending" || !strings.Contains(s.cloud.probeMessage, "405") {
		t.Fatal("restriction drained the queue or hid the failure", calls, st)
	}
}

func TestCloudQueueRestartPreservesOrderAndOnlyResumesQueuedItems(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	ids := queueCloudItems(t, s, "B", "A")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.ctx = ctx
	started := make(chan struct{})
	s.cloud.probe = func(ctx context.Context, item CloudItem) (Track, error) {
		close(started)
		<-ctx.Done()
		return Track{}, ctx.Err()
	}
	if err := s.cloud.start("probe", ""); err != nil {
		t.Fatal(err)
	}
	<-started
	cancel()
	s.cloud.wg.Wait()
	queueCloudItems(t, s, "Unqueued")
	store, err := OpenStore(s.config.DataDir)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(store.state.Cloud.ProbeQueue, []string{ids[1], ids[0]}) {
		t.Fatal("queue did not survive reopening in FIFO order")
	}
	s.store, s.ctx = store, context.Background()
	s.cloud = newCloud115(s)
	var order []string
	s.cloud.probe = func(ctx context.Context, item CloudItem) (Track, error) {
		order = append(order, item.FileID)
		return Track{Title: item.Name, Duration: 1}, nil
	}
	if err := s.cloud.start("resume", ""); err != nil {
		t.Fatal(err)
	}
	s.cloud.wg.Wait()
	if !reflect.DeepEqual(order, []string{"A", "B"}) {
		t.Fatal("restart probed unqueued music or reordered the queue", order)
	}
	if s.cloud.snapshot().Items[cloudTrackID("42", "Unqueued")].State != "pending" {
		t.Fatal("unqueued pending item changed")
	}
}

func TestCloudQueueDiscardsStaleProbeAndMissingItems(t *testing.T) {
	for _, missing := range []bool{false, true} {
		t.Run(map[bool]string{false: "changed", true: "removed"}[missing], func(t *testing.T) {
			s := testServer(t)
			seedCloud(t, s)
			id := queueCloudItems(t, s, "A")[0]
			calls := 0
			s.cloud.probe = func(ctx context.Context, item CloudItem) (Track, error) {
				calls++
				if calls == 1 {
					if err := s.store.update(func(st *libraryState) error {
						current := st.Cloud.Items[id]
						current.Fingerprint, current.State = "new-version", "pending"
						if missing {
							current.State = "missing"
						}
						st.Cloud.Items[id] = current
						return nil
					}); err != nil {
						t.Error(err)
					}
					return Track{Title: "Stale"}, nil
				}
				return Track{Title: "Current"}, nil
			}
			if err := s.cloud.start("probe", ""); err != nil {
				t.Fatal(err)
			}
			s.cloud.wg.Wait()
			track, exists := s.store.Track(id)
			if missing {
				if calls != 1 || exists {
					t.Fatal("removed file was published", calls, track)
				}
			} else if calls != 2 || !exists || track.Title != "Current" {
				t.Fatal("stale metadata published", calls, track)
			}
			if len(s.cloud.snapshot().ProbeQueue) != 0 {
				t.Fatal("queue not drained")
			}
		})
	}
}

func TestCloudQueuePersistenceFailureRollsBack(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	ids := queueCloudItems(t, s, "A", "B", "C")
	s.cloud.mu.Lock()
	defer s.cloud.mu.Unlock()
	if err := s.cloud.enqueue("probe", ids[0]); err != nil {
		t.Fatal(err)
	}
	before := s.cloud.snapshot()
	before.ProbeQueue[0] = "modified copy"
	if s.cloud.snapshot().ProbeQueue[0] != ids[0] {
		t.Fatal("snapshot exposed the queue slice")
	}
	if err := s.store.update(func(st *libraryState) error {
		st.Cloud.ProbeQueue[0] = "should roll back"
		return errors.New("failed transaction")
	}); err == nil || s.cloud.snapshot().ProbeQueue[0] != ids[0] {
		t.Fatal("failed update mutated the durable queue")
	}
}

func TestCloudBasicEntriesDoNotBlockDeduplicationOrLoseFavorites(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	ids := queueCloudItems(t, s, "A", "B")
	paths := map[string]string{}
	for _, id := range ids {
		item := s.cloud.snapshot().Items[id]
		if err := s.cloud.writeSTRM(item); err != nil {
			t.Fatal(err)
		}
		paths[id] = s.cloud.strmPath(item)
	}
	if err := s.store.update(func(st *libraryState) error {
		for _, id := range ids {
			item := st.Cloud.Items[id]
			remote := item.RemoteFile
			st.Tracks[id] = DiskTrack{Track: Track{ID: id, Title: "Song", Artist: "Artist",
				Library: "cloud", MetadataSource: "filename", Favorite: true, AddedAt: time.Now()},
				Remote: &remote, File: paths[id]}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	s.cloud.probe = func(ctx context.Context, item CloudItem) (Track, error) {
		return Track{Title: "Song", Artist: "Artist", AlbumArtist: "Artist", Album: "Album", Duration: 1, MetadataSource: "tags"}, nil
	}
	if err := s.cloud.start("probe", ""); err != nil {
		t.Fatal(err)
	}
	s.cloud.wg.Wait()
	tracks := s.store.Tracks()
	if len(tracks) != 1 || tracks[0].ID != ids[0] || !tracks[0].Favorite || tracks[0].MetadataSource != "tags" {
		t.Fatal("basic entries prevented real metadata publication or deduplication", tracks)
	}
	if skipped, ok := s.store.Track(ids[1]); !ok || !skipped.Favorite || !skipped.Unavailable ||
		s.cloud.snapshot().Items[ids[1]].State != "skipped" {
		t.Fatal("deduplication discarded the cached favorite", skipped)
	}
}
