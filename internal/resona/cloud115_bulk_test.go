package resona

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"
)

func cloudRootInfo(w http.ResponseWriter) {
	cloudResponse(w, []any{map[string]any{"file_id": "10", "pick_code": "abcdefghijklmnopq"}})
}

func TestCloudMetaCineBulkTreeManyDirectories(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	nodes, files := []any{}, []any{}
	for i := 0; i < 100; i++ {
		id := fmt.Sprint(100 + i)
		nodes = append(nodes, map[string]any{"fid": id, "pid": "10", "fn": fmt.Sprintf("Album-%03d", i)})
		files = append(files, treeFile(fmt.Sprint(1000+i), id, "Song.flac"))
	}
	calls := map[string]int{}
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls[r.URL.Path]++
		switch r.URL.Path {
		case "/files/get_info":
			cloudRootInfo(w)
		case "/app/2.0/chrome/downfolders":
			cloudResponse(w, map[string]any{"has_next_page": false, "count": 100, "list": nodes})
		case "/files":
			if r.URL.Query().Get("cur") != "0" {
				t.Error("listed individual directory")
			}
			jsonResponse(w, 200, map[string]any{"state": true, "cid": 10, "path": []any{map[string]any{"cid": 10}}, "count": 100, "data": files})
		default:
			t.Error("unexpected endpoint", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer api.Close()
	s.cloud.webURL, s.cloud.apiURL = api.URL, api.URL
	result, err := s.cloud.tree(t.Context(), "10")
	if err != nil || len(result) != 100 {
		t.Fatal("bulk sync", len(result), err)
	}
	for i, f := range result {
		if f.Path != filepath.Join(fmt.Sprintf("Album-%03d", i), "Song.flac") {
			t.Fatal("incorrect path", f.Path)
		}
	}
	if len(calls) != 3 || calls["/files/get_info"] != 1 || calls["/app/2.0/chrome/downfolders"] != 1 || calls["/files"] != 1 {
		t.Fatal("bulk tree should need only three requests for 100 folders", calls)
	}
}

func TestCloudMetaCineTreeFallback(t *testing.T) {
	for _, mode := range []string{"no-pickcode", "truncated-tree", "tree-405", "recursive-405", "invalid-tree", "root-zero"} {
		t.Run(mode, func(t *testing.T) {
			s := testServer(t)
			seedCloud(t, s)
			walks, recursive := 0, 0
			root := "10"
			if mode == "root-zero" {
				root = "0"
			}
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				q := r.URL.Query()
				switch r.URL.Path {
				case "/files/file":
					cloudResponse(w, []any{map[string]any{"file_id": "10"}})
				case "/files/get_info":
					if mode == "no-pickcode" {
						cloudResponse(w, []any{map[string]any{"file_id": "10"}})
					} else {
						cloudRootInfo(w)
					}
				case "/app/2.0/chrome/downfolders":
					if mode == "tree-405" {
						w.Header().Set("Retry-After", "1")
						w.WriteHeader(405)
						return
					}
					more, parent := false, "10"
					if mode == "truncated-tree" {
						more = true
						cloudResponse(w, map[string]any{"has_next_page": more, "list": []any{}})
						return
					}
					if mode == "invalid-tree" {
						parent = "99"
					}
					cloudResponse(w, map[string]any{"has_next_page": more, "list": []any{map[string]any{"fid": 20, "pid": parent, "fn": "Album"}}})
				case "/files":
					if q.Get("cur") == "0" {
						recursive++
						w.Header().Set("Retry-After", "1")
						w.WriteHeader(405)
						return
					}
					walks++
					parent := q.Get("cid")
					data := []any{treeFile("1", parent, "Song.mp3")}
					if parent == root {
						data = []any{map[string]any{"cid": "20", "pid": parent, "n": "Album"}}
					}
					jsonResponse(w, 200, map[string]any{"state": true, "cid": parent, "path": []any{map[string]any{"cid": parent}}, "count": len(data), "data": data})
				default:
					t.Error("unexpected endpoint", r.URL.Path)
					w.WriteHeader(404)
				}
			}))
			defer api.Close()
			s.cloud.webURL, s.cloud.apiURL = api.URL, api.URL
			files, err := s.cloud.tree(t.Context(), root)
			if err != nil || len(files) != 1 || files[0].Path != filepath.Join("Album", "Song.mp3") || walks != 2 {
				t.Fatal("fallback lost or duplicated files", files, walks, err)
			}
			if mode == "recursive-405" && recursive != 4 || mode != "recursive-405" && recursive != 0 {
				t.Fatal("unexpected recursive attempts", recursive)
			}
		})
	}
}

func TestCloudBulkTreePaginationAndValidation(t *testing.T) {
	for _, failure := range []string{"", "cycle", "missing-parent", "duplicate-node", "truncated-tree", "changed-tree-count", "missing-more", "duplicate-file", "truncated-files", "changed-file-count", "wrong-root", "wrong-path", "outside-file", "invalid-name"} {
		t.Run(failure, func(t *testing.T) {
			s := testServer(t)
			seedCloud(t, s)
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				q := r.URL.Query()
				switch r.URL.Path {
				case "/files/get_info":
					cloudRootInfo(w)
				case "/app/2.0/chrome/downfolders":
					page, _ := strconv.Atoi(q.Get("page"))
					id, parent, name := "20", "10", "Artist"
					if page == 2 {
						id, parent, name = "30", "20", "Album"
					}
					switch failure {
					case "cycle":
						if page == 1 {
							parent = "30"
						}
					case "missing-parent":
						if page == 1 {
							parent = "99"
						}
					case "duplicate-node":
						if page == 2 {
							id = "20"
						}
					case "invalid-name":
						name = "../Escape"
					}
					count := 2
					if failure == "changed-tree-count" && page == 2 {
						count = 3
					}
					more := any(page == 1)
					if failure == "missing-more" {
						more = nil
					}
					nodes := []any{map[string]any{"fid": id, "pid": parent, "fn": name}}
					if failure == "truncated-tree" && page == 2 {
						nodes = nil
					}
					cloudResponse(w, map[string]any{"count": count, "has_next_page": more, "list": nodes})
				case "/files":
					offset, _ := strconv.Atoi(q.Get("offset"))
					f := treeFile(fmt.Sprint(1+offset), "30", fmt.Sprintf("Song%d.mp3", offset))
					count, cid, path := 2, "10", "10"
					switch failure {
					case "duplicate-file":
						f["fid"] = "1"
					case "changed-file-count":
						if offset > 0 {
							count = 3
						}
					case "wrong-root":
						cid = "0"
					case "wrong-path":
						path = "0"
					case "outside-file":
						f["cid"] = "99"
					}
					data := []any{f}
					if failure == "truncated-files" && offset > 0 {
						data = nil
					}
					jsonResponse(w, 200, map[string]any{"state": true, "cid": cid, "path": []any{map[string]any{"cid": path}}, "count": count, "data": data})
				default:
					t.Error("unexpected endpoint", r.URL.Path)
					w.WriteHeader(404)
				}
			}))
			defer api.Close()
			s.cloud.webURL, s.cloud.apiURL = api.URL, api.URL
			files, err := s.cloud.bulkTree(t.Context(), "10")
			if failure != "" {
				if err == nil || files != nil {
					t.Fatal("invalid tree accepted", files, err)
				}
			} else if err != nil || len(files) != 2 || files[0].Path != filepath.Join("Artist", "Album", "Song0.mp3") {
				t.Fatal("valid paginated tree rejected", files, err)
			}
		})
	}
}

func TestCloudBulkCancellationAndAuthDoNotFallback(t *testing.T) {
	for _, mode := range []string{"cancelled", "auth"} {
		t.Run(mode, func(t *testing.T) {
			s := testServer(t)
			seedCloud(t, s)
			calls := 0
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++; w.WriteHeader(401) }))
			defer api.Close()
			s.cloud.webURL, s.cloud.apiURL = api.URL, api.URL
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			if mode == "cancelled" {
				cancel()
			}
			_, err := s.cloud.tree(ctx, "10")
			if mode == "cancelled" {
				if !errors.Is(err, context.Canceled) || calls != 0 {
					t.Fatal("cancelled task requested data", calls, err)
				}
			} else if !errors.Is(err, errCloudAuth) || calls != 1 || s.cloud.snapshot().Cookie != "" {
				t.Fatal("expired login retried or fell back", calls, err)
			}
		})
	}
}

func TestCloudFailedFallbackPreservesPublishedLibrary(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	id := cloudTrackID("42", "99")
	if err := s.store.update(func(st *libraryState) error {
		st.Cloud.Settings.RootID = "10"
		st.Cloud.Items[id] = CloudItem{RemoteFile: RemoteFile{Account: "42", FileID: "99"}, TrackID: id, State: "ready"}
		st.Tracks[id] = DiskTrack{Track: Track{ID: id, Favorite: true}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/files/get_info":
			cloudRootInfo(w)
		case "/app/2.0/chrome/downfolders":
			cloudResponse(w, map[string]any{"has_next_page": true, "list": []any{}})
		case "/files":
			data := []any{treeFile("1", "10", "New Song.mp3"), map[string]any{"cid": 20, "pid": 10, "n": "Album"}}
			parent := r.URL.Query().Get("cid")
			if parent == "20" {
				data = nil
			} // The second folder is truncated.
			jsonResponse(w, 200, map[string]any{"state": true, "cid": parent, "path": []any{map[string]any{"cid": parent}}, "count": 2, "data": data})
		default:
			t.Error("unexpected endpoint", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer api.Close()
	s.cloud.webURL, s.cloud.apiURL = api.URL, api.URL
	if err := s.cloud.generate(t.Context()); err == nil {
		t.Fatal("incomplete fallback committed")
	}
	state := s.cloud.snapshot()
	track, _ := s.store.Track(id)
	if len(state.Items) != 1 || state.Items[id].State != "ready" || !state.LastSync.IsZero() || !track.Favorite || track.Unavailable {
		t.Fatal("failed fallback changed previously published library", state, track)
	}
}
