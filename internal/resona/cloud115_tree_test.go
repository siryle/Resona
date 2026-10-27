package resona

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func treeFile(id, parent, name string) map[string]any {
	return map[string]any{"fid": id, "cid": parent, "n": name, "pc": "abcdefghijklmnopq", "sha": strings.Repeat("A", 40), "s": 100}
}

func TestCloudTreeBulkGenerationAndSiblingBoundaries(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	if err := s.store.update(func(st *libraryState) error { st.Cloud.Settings.RootID = "10"; return nil }); err != nil {
		t.Fatal(err)
	}
	files := []any{treeFile("1", "20", "Song.mp3"), treeFile("2", "20", "Other.flac"),
		treeFile("3", "20", "cover.jpg"), treeFile("4", "20", "Song.lrc"), treeFile("5", "10", "Song.mp3")}
	listCalls, treeCalls, infoCalls := 0, 0, 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.UserAgent() != cloudDirectoryUA || !strings.Contains(r.Header.Get("Cookie"), "private-cid") || r.Header.Get("Authorization") != "" {
			t.Error("directory requests must use reference web UA and server-side Cookie")
		}
		q := r.URL.Query()
		switch r.URL.Path {
		case "/files":
			listCalls++
			if q.Get("cur") != "0" || q.Get("show_dir") != "0" || q.Get("count_folders") != "0" || q.Get("cid") != "10" {
				t.Error("not using recursive directory-tree listing", q)
			}
			offset, _ := strconv.Atoi(q.Get("offset"))
			end := min(offset+2, len(files))
			jsonResponse(w, 200, map[string]any{"state": true, "cid": "10", "path": []any{map[string]any{"cid": "10"}}, "count": len(files), "offset": offset, "data": files[offset:end]})
		case "/files/get_info":
			infoCalls++
			if q.Get("file_id") != "10" {
				t.Error("wrong root ID", q)
			}
			cloudResponse(w, []any{map[string]any{"file_id": "10", "pick_code": "root-pick-code"}})
		case "/app/2.0/chrome/downfolders":
			treeCalls++
			if q.Get("pickcode") != "root-pick-code" || q.Get("per_page") != "5000" {
				t.Error("wrong tree request", q)
			}
			cloudResponse(w, map[string]any{"count": "1", "has_next_page": false, "list": []any{
				map[string]any{"fid": 20, "pid": 10, "fn": "Album"},
			}})
		default:
			t.Error("unexpected API", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer api.Close()
	s.cloud.webURL, s.cloud.apiURL = api.URL, api.URL
	probes := 0
	s.cloud.probe = func(_ context.Context, item CloudItem) (Track, error) {
		probes++
		items := s.cloud.snapshot().Items
		if len(items) != 3 {
			t.Fatal("sidecars indexed as music", len(items))
		}
		// Even the first probe must see every STRM, not just its own file.
		for _, other := range items {
			path := s.cloud.strmPath(other)
			data, err := os.ReadFile(path)
			if err != nil || !strings.Contains(string(data), other.TrackID+"/stream") {
				t.Fatal("bulk STRM generation incomplete", path, err)
			}
			for current := path; ; current = filepath.Dir(current) {
				info, err := os.Stat(current)
				if err != nil || info.Mode().Perm() != 0777 {
					t.Fatal("STRM tree permissions", current, info, err)
				}
				if current == filepath.Join(s.config.DataDir, "cloud115", "strm") {
					break
				}
			}
		}
		if item.FileID == "5" {
			if item.Cover != nil || item.LRC != nil || item.Path != "Song.mp3" {
				t.Error("sibling sidecars leaked across directories", item)
			}
		} else if item.Cover == nil || item.Cover.FileID != "3" || (item.FileID == "1" && (item.LRC == nil || item.LRC.FileID != "4")) {
			t.Error("sibling sidecars missing", item)
		}
		return Track{}, fmt.Errorf("hold publication for bulk-generation test")
	}
	if err := s.cloud.generate(context.Background()); err != nil {
		t.Fatal(err)
	}
	if probes != 0 || len(s.store.Tracks()) != 3 {
		t.Fatal("generation must refresh the library without probing", probes)
	}
	if err := s.cloud.start("probe", ""); err != nil {
		t.Fatal(err)
	}
	s.cloud.wg.Wait()
	if listCalls != 3 || treeCalls != 1 || infoCalls != 1 || probes != 3 {
		t.Fatal("unexpected request/probe counts", listCalls, treeCalls, infoCalls, probes)
	}
}

func TestCloudTreeFailuresPreserveIndex(t *testing.T) {
	for _, mode := range []string{"405", "duplicate", "changed-count", "empty-page", "wrong-offset", "wrong-root", "wrong-path", "outside-root", "cycle", "invalid-music", "invalid-name"} {
		t.Run(mode, func(t *testing.T) {
			s := testServer(t)
			seedCloud(t, s)
			id := cloudTrackID("42", "99")
			if err := s.store.update(func(st *libraryState) error {
				st.Cloud.Items[id] = CloudItem{RemoteFile: RemoteFile{Account: "42", FileID: "99"}, TrackID: id, State: "ready"}
				st.Tracks[id] = DiskTrack{Track: Track{ID: id, Favorite: true}}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			before := s.cloud.snapshot()
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if mode == "405" {
					w.Header().Set("Retry-After", "1")
					w.WriteHeader(405)
					return
				}
				offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
				file := treeFile("1", "0", "Song.mp3")
				count, cid, path := 2, "0", "0"
				data := []any{file}
				switch mode {
				case "changed-count":
					if offset > 0 {
						count = 3
					}
				case "empty-page":
					if offset > 0 {
						data = nil
					}
				case "wrong-offset":
					offset++
				case "wrong-root":
					cid = "11"
				case "wrong-path":
					path = "11"
				case "outside-root":
					count = 1
					file["cid"] = "20"
				case "cycle":
					count = 1
					file = map[string]any{"cid": "0", "pid": "0", "n": "Cycle"}
					data = []any{file}
				case "invalid-music":
					count = 1
					file["sha"] = "invalid"
				case "invalid-name":
					count = 1
					file["n"] = "../Song.mp3"
				}
				jsonResponse(w, 200, map[string]any{"state": true, "count": count, "cid": cid, "path": []any{map[string]any{"cid": path}}, "offset": offset, "data": data})
			}))
			defer api.Close()
			s.cloud.webURL, s.cloud.apiURL = api.URL, api.URL
			err := s.cloud.generate(context.Background())
			if err == nil || (mode == "405" && !strings.Contains(err.Error(), "405")) {
				t.Fatal("invalid tree accepted", err)
			}
			if after := s.cloud.snapshot(); !reflect.DeepEqual(before, after) {
				t.Fatal("failed sync changed cloud index", after)
			}
			track, _ := s.store.Track(id)
			if track.Unavailable || !track.Favorite {
				t.Fatal("failed sync damaged existing track")
			}
		})
	}
}

func TestCloudDirectoryBrowserAndFieldAliases(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("cur") != "1" || r.URL.Query().Get("show_dir") != "1" {
			t.Error("browser must list immediate children")
		}
		jsonResponse(w, 200, map[string]any{"state": true, "cid": 0, "path": []any{map[string]any{"cid": 0}}, "count": 1, "data": []any{map[string]any{"cid": "354777220162357189", "pid": 0, "n": "Folder"}}})
	}))
	defer api.Close()
	s.cloud.webURL, s.cloud.apiURL = api.URL, api.URL
	files, err := s.cloud.list(context.Background(), "0")
	if err != nil || len(files) != 1 || files[0].Category != "0" || files[0].Name != "Folder" || files[0].ID != "354777220162357189" {
		t.Fatal("folder browser", files, err)
	}
	var f cloudFile
	if err := json.Unmarshal([]byte(`{"fid":"1","pid":"0","file_name":"Song.mp3","sha1":"abc","fs":"12","fc":1}`), &f); err != nil || f.Name != "Song.mp3" || f.SHA1 != "abc" || f.Size != "12" {
		t.Fatal("file aliases", f, err)
	}
	if err := json.Unmarshal([]byte(`{"fid":1,"cid":354777220162357189,"pid":0,"n":"Song.mp3","s":12}`), &f); err != nil || f.ParentID != "354777220162357189" || f.Category != "1" {
		t.Fatal("Web parent ID must override pid without losing integer precision", f, err)
	}
}

func TestCloudTreeIncrementalSyncAndMissingFiles(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	files := []any{treeFile("1", "0", "Song.mp3"), treeFile("2", "0", "Other.mp3")}
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jsonResponse(w, 200, map[string]any{"state": true, "cid": 0, "path": []any{map[string]any{"cid": 0}}, "count": len(files), "data": files})
	}))
	defer api.Close()
	s.cloud.webURL, s.cloud.apiURL = api.URL, api.URL
	ctx := context.Background()
	if err := s.cloud.syncTree(ctx); err != nil {
		t.Fatal(err)
	}
	id, removed := cloudTrackID("42", "1"), cloudTrackID("42", "2")
	if err := s.store.update(func(st *libraryState) error {
		for _, key := range []string{id, removed} {
			item := st.Cloud.Items[key]
			item.State = "ready"
			st.Cloud.Items[key] = item
			st.Tracks[key] = DiskTrack{Track: Track{ID: key, Favorite: true}}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.cloud.syncTree(ctx); err != nil {
		t.Fatal(err)
	}
	if s.cloud.snapshot().Items[id].State != "ready" {
		t.Fatal("unchanged song was requeued")
	}
	files = files[:1]
	files[0].(map[string]any)["sha"] = strings.Repeat("B", 40)
	if err := s.cloud.syncTree(ctx); err != nil {
		t.Fatal(err)
	}
	items := s.cloud.snapshot().Items
	if items[id].State != "pending" || items[removed].State != "missing" {
		t.Fatal("changed/missing states", items)
	}
	for _, key := range []string{id, removed} {
		track, _ := s.store.Track(key)
		if !track.Unavailable || !track.Favorite {
			t.Fatal("incremental sync lost favorite or failed to invalidate audio")
		}
	}
	files = []any{treeFile("1", "0", "Song.mp3"), treeFile("2", "0", "Other.mp3")}
	if err := s.cloud.syncTree(ctx); err != nil {
		t.Fatal(err)
	}
	if s.cloud.snapshot().Items[removed].State != "pending" {
		t.Fatal("reappearing file not queued")
	}
}
