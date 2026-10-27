package resona

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestCloudJavStrmPickCodeSupplementAndRecursiveListing(t *testing.T) {
	for _, shape := range []string{"object", "array", "short", "supplement", "supplement-numeric"} {
		t.Run(shape, func(t *testing.T) {
			s := testServer(t)
			seedCloud(t, s)
			calls := []string{}
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls = append(calls, r.URL.Path)
				switch r.URL.Path {
				case "/files/get_info":
					entry := map[string]any{"file_id": "10", "file_category": "0"}
					switch shape {
					case "object", "array":
						entry["pickcode"] = "root-pc"
					case "short":
						entry = map[string]any{"cid": 10, "pc": "root-pc"}
					}
					if shape == "array" {
						cloudResponse(w, []any{entry})
					} else {
						cloudResponse(w, entry)
					}
				case "/files/file":
					var id any = "10"
					if shape == "supplement-numeric" {
						id = 10
					}
					cloudResponse(w, []any{map[string]any{"file_id": id, "pick_code": "root-pc"}})
				case "/app/2.0/chrome/downfolders":
					if r.URL.Query().Get("pickcode") != "root-pc" {
						t.Error("incorrect PickCode")
					}
					cloudResponse(w, map[string]any{"has_next_page": false, "count": 1,
						"list": []any{map[string]any{"fid": "20", "pid": "10", "fn": "Album"}}})
				case "/files":
					q := r.URL.Query()
					if q.Get("cur") != "0" || q.Get("type") != "99" || q.Get("limit") != "5000" {
						t.Error("not using JavStrm recursive file listing", q)
					}
					// Cookie recursive listings need not return a breadcrumb path.
					jsonResponse(w, 200, map[string]any{"state": true, "cid": "10", "count": 1,
						"data": []any{treeFile("1", "20", "Song.mp3")}})
				default:
					t.Error("unexpected endpoint", r.URL.Path)
					w.WriteHeader(404)
				}
			}))
			defer api.Close()
			s.cloud.webURL, s.cloud.apiURL = api.URL, api.URL
			files, err := s.cloud.bulkTree(t.Context(), "10")
			want := []string{"/files/get_info", "/app/2.0/chrome/downfolders", "/files"}
			if strings.HasPrefix(shape, "supplement") {
				want = []string{"/files/get_info", "/files/file", "/app/2.0/chrome/downfolders", "/files"}
			}
			if err != nil || len(files) != 1 || files[0].Path != filepath.Join("Album", "Song.mp3") || !reflect.DeepEqual(calls, want) {
				t.Fatal("JavStrm fast path failed", files, calls, err)
			}
		})
	}
}

func TestCloudGenerationStartProgressAndStopDuringBlockedTree(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	token := loginToken(t, s)
	started := make(chan struct{})
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
	}))
	defer api.Close()
	s.cloud.webURL = api.URL
	result := request(s.Handler(), "POST", "/api/v1/cloud115/sync", `{}`, token)
	if result.Code != 202 {
		t.Fatal("start was not accepted", result.Code, result.Body.String())
	}
	<-started
	done := make(chan struct{})
	go func() {
		defer close(done)
		status := request(s.Handler(), "GET", "/api/v1/cloud115/progress", "", token)
		if status.Code != 200 || !strings.Contains(status.Body.String(), `"sync_busy":true`) ||
			strings.Contains(status.Body.String(), `"items"`) || strings.Contains(status.Body.String(), "private") {
			t.Error("lightweight progress invalid", status.Body.String())
		}
		s.store.Tracks()
		for range 2 {
			stop := request(s.Handler(), "POST", "/api/v1/cloud115/sync/stop", `{}`, token)
			if stop.Code != 202 {
				t.Error("stop was not accepted", stop.Code)
			}
		}
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("task control blocked behind directory scan")
	}
	s.cloud.wg.Wait()
	data := s.cloud.progressData()
	if data["busy"] != false || !strings.Contains(data["message"].(string), "已终止") {
		t.Fatal("cancelled task remained busy", data)
	}
	if len(s.store.Tracks()) != 0 || !s.cloud.snapshot().LastSync.IsZero() {
		t.Fatal("cancelled discovery published partial results")
	}
}

func TestCloudProbeStopPreservesQueueAndManualPauseAcrossRestart(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	ids := queueCloudItems(t, s, "A", "B")
	token := loginToken(t, s)
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
	result := request(s.Handler(), "POST", "/api/v1/cloud115/probe/stop", `{}`, token)
	if result.Code != 202 {
		t.Fatal(result.Body.String())
	}
	s.cloud.wg.Wait()
	state := s.cloud.snapshot()
	if !state.ProbePaused || !reflect.DeepEqual(state.ProbeQueue, ids) || state.Items[ids[0]].State != "pending" {
		t.Fatal("manual stop lost queue or marked current song failed", state)
	}
	store, err := OpenStore(s.config.DataDir)
	if err != nil {
		t.Fatal(err)
	}
	s.store, s.cloud = store, newCloud115(s)
	calls := 0
	s.cloud.probe = func(ctx context.Context, item CloudItem) (Track, error) {
		calls++
		return Track{Title: item.Name, Duration: 1}, nil
	}
	if err := s.cloud.start("resume", ""); err != nil {
		t.Fatal(err)
	}
	s.cloud.wg.Wait()
	if calls != 0 || !reflect.DeepEqual(s.cloud.snapshot().ProbeQueue, ids) {
		t.Fatal("restart ignored manual pause")
	}
	if err := s.cloud.start("probe", ""); err != nil {
		t.Fatal(err)
	}
	s.cloud.wg.Wait()
	if calls != 2 || s.cloud.snapshot().ProbePaused || len(s.cloud.snapshot().ProbeQueue) != 0 {
		t.Fatal("explicit resume did not finish the preserved queue")
	}
}

func TestCloudTaskStopsAreIndependent(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	queueCloudItems(t, s, "A", "B")
	token := loginToken(t, s)
	probing, scanning := make(chan struct{}), make(chan struct{})
	s.cloud.probe = func(ctx context.Context, item CloudItem) (Track, error) {
		close(probing)
		<-ctx.Done()
		return Track{}, ctx.Err()
	}
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(scanning)
		<-r.Context().Done()
	}))
	defer api.Close()
	s.cloud.webURL = api.URL
	if err := s.cloud.start("probe", ""); err != nil {
		t.Fatal(err)
	}
	<-probing
	if err := s.cloud.start("sync", ""); err != nil {
		t.Fatal(err)
	}
	<-scanning
	if result := request(s.Handler(), "POST", "/api/v1/cloud115/sync/stop", `{}`, token); result.Code != 202 {
		t.Fatal(result.Body.String())
	}
	waitCloud(t, func() bool { return s.cloud.progressData()["sync_busy"] == false })
	if s.cloud.progressData()["probe_busy"] != true {
		t.Fatal("stopping generation also stopped the independent probe")
	}
	if result := request(s.Handler(), "POST", "/api/v1/cloud115/probe/stop", `{}`, token); result.Code != 202 {
		t.Fatal(result.Body.String())
	}
	s.cloud.wg.Wait()
	if s.cloud.progressData()["busy"] != false || len(s.cloud.snapshot().ProbeQueue) != 2 {
		t.Fatal("stop failed to release tasks or retain queue")
	}
}

func TestCloudStopCancelsWaitingForAPIGate(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	s.cloud.apiGate <- struct{}{}
	defer func() { <-s.cloud.apiGate }()
	if err := s.cloud.start("sync", ""); err != nil {
		t.Fatal(err)
	}
	result := request(s.Handler(), "POST", "/api/v1/cloud115/sync/stop", `{}`, loginToken(t, s))
	if result.Code != 202 {
		t.Fatal(result.Body.String())
	}
	waitCloud(t, func() bool { return s.cloud.progressData()["sync_busy"] == false })
	s.cloud.wg.Wait()
}

func TestCloudStopCancelsWaitingForDownloadGate(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	queueCloudItems(t, s, "A")
	s.cloud.linkGate <- struct{}{}
	defer func() { <-s.cloud.linkGate }()
	if err := s.cloud.start("probe", ""); err != nil {
		t.Fatal(err)
	}
	waitCloud(t, func() bool { return s.cloud.progressData()["probe_current"] != "" })
	result := request(s.Handler(), "POST", "/api/v1/cloud115/probe/stop", `{}`, loginToken(t, s))
	if result.Code != 202 {
		t.Fatal(result.Body.String())
	}
	waitCloud(t, func() bool { return s.cloud.progressData()["probe_busy"] == false })
	s.cloud.wg.Wait()
	if !s.cloud.snapshot().ProbePaused || len(s.cloud.snapshot().ProbeQueue) != 1 {
		t.Fatal("cancellation while waiting for download lost the probe queue")
	}
}

func TestCloudSnapshotSaveDoesNotBlockReadersAndRollsBack(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	old := s.cloud.summary()
	started, release, finished := make(chan struct{}), make(chan struct{}), make(chan error, 1)
	go func() {
		finished <- s.store.updateCloud(func(st *libraryState) error {
			st.Cloud.Settings.RootID = "99"
			close(started)
			<-release
			return errors.New("save failed")
		})
	}()
	<-started
	read := make(chan struct{})
	go func() {
		s.store.Tracks()
		s.cloud.progressData()
		close(read)
	}()
	select {
	case <-read:
	case <-time.After(time.Second):
		close(release)
		t.Fatal("cloud publication blocked index readers")
	}
	if s.cloud.summary().Settings.RootID != old.Settings.RootID {
		t.Error("uncommitted cloud state became visible")
	}
	close(release)
	if <-finished == nil || s.cloud.summary().Settings.RootID != old.Settings.RootID {
		t.Fatal("failed cloud update did not roll back")
	}
}

func TestCloudSTRMWriterSkipsUnchangedAndContainsPaths(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	id := queueCloudItems(t, s, "Song")[0]
	item := s.cloud.snapshot().Items[id]
	path := s.cloud.strmPath(item)
	writer := s.cloud.newSTRMWriter()
	defer writer.close()
	if same, err := writer.write(t.Context(), item, path); err != nil || same {
		t.Fatal("initial write", same, err)
	}
	oldTime := time.Unix(1000000000, 0)
	if err := os.Chtimes(path, oldTime, oldTime); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	if same, err := writer.write(t.Context(), item, path); err != nil || !same {
		t.Fatal("unchanged file was rewritten", same, err)
	}
	info, _ := os.Stat(path)
	if !info.ModTime().Equal(oldTime) || info.Mode().Perm() != 0777 {
		t.Fatal("unchanged mtime or permissions incorrect", info)
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := writer.write(ctx, item, path); !errors.Is(err, context.Canceled) {
		t.Fatal("writer ignored cancellation", err)
	}
	writer.base = "https://new.example.com"
	if same, err := writer.write(t.Context(), item, path); err != nil || same {
		t.Fatal("changed URL was not updated", same, err)
	}
	content, _ := os.ReadFile(path)
	if !strings.HasPrefix(string(content), writer.base) {
		t.Fatal("stale URL", string(content))
	}
	outside := filepath.Join(t.TempDir(), "outside.strm")
	if err := os.WriteFile(outside, []byte("unchanged"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, path); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.write(t.Context(), item, path); err == nil {
		t.Fatal("symlink output accepted")
	}
	outsideData, _ := os.ReadFile(outside)
	if string(outsideData) != "unchanged" {
		t.Fatal("writer modified an external file")
	}
	// A caller cannot use an unrelated directory even after its parent was cached.
	if _, err := writer.write(t.Context(), item, outside); err == nil {
		t.Fatal("external destination accepted")
	}
	data, err := json.Marshal(s.cloud.progressData())
	if err != nil || strings.Contains(string(data), "cookie") {
		t.Fatal("task progress exposed credentials", string(data), err)
	}
}
