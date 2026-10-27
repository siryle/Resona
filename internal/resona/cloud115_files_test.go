package resona

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestCloudFileManagerBoundariesAndReferenceOperations(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	token := loginToken(t, s)
	type mutation struct {
		path string
		form url.Values
	}
	var mutations []mutation
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Cookie"), "private-cid") || r.Header.Get("Authorization") != "" {
			t.Error("file management must use server-side Cookie")
		}
		if r.Method == "POST" {
			r.ParseForm()
			mutations = append(mutations, mutation{r.URL.Path, r.PostForm})
			cloudResponse(w, nil)
			return
		}
		parent := r.URL.Query().Get("cid")
		items := []any{}
		switch parent {
		case "0":
			items = []any{map[string]any{"cid": "10", "pid": "0", "n": "Music", "fc": "0"},
				map[string]any{"cid": "20", "pid": "0", "n": "Target", "fc": "0"}}
		case "10":
			items = []any{treeFile("1", "10", "Song.mp3"), treeFile("2", "10", "Song.lrc")}
		case "20":
			items = []any{treeFile("3", "20", "Existing.mp3")}
		}
		jsonResponse(w, 200, map[string]any{"state": true, "cid": parent,
			"path": []any{map[string]string{"cid": parent}}, "count": len(items), "data": items})
	}))
	defer api.Close()
	s.cloud.webURL = api.URL
	for _, path := range []string{"/api/v1/cloud115/files", "/api/v1/cloud115/files/operations"} {
		method, body := "GET", ""
		if strings.HasSuffix(path, "operations") {
			method, body = "POST", `{}`
		}
		if w := request(s.Handler(), method, path, body, ""); w.Code != 401 {
			t.Fatal("file manager exposed")
		}
	}
	w := request(s.Handler(), "GET", "/api/v1/cloud115/files?path=/Music", "", token)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Song.lrc") || strings.Contains(w.Body.String(), "private-cid") {
		t.Fatal("cloud file listing failed", w.Code, w.Body.String())
	}
	for _, body := range []string{
		`{"action":"rename","paths":["/Music/Song.mp3"],"target":"/Music/Song.lrc"}`,
		`{"action":"copy","paths":["/Music"],"target":"/Music"}`,
		`{"action":"delete","paths":["/"]}`,
		`{"action":"delete","paths":["/Music","/Music/Song.mp3"]}`,
		`{"action":"move","paths":["/Music/Song.mp3"],"target":"/Target/../Music"}`,
	} {
		if w := request(s.Handler(), "POST", "/api/v1/cloud115/files/operations", body, token); w.Code < 400 {
			t.Fatal("unsafe/conflicting operation accepted", body, w.Body.String())
		}
	}
	if len(mutations) != 0 {
		t.Fatal("validation modified upstream files")
	}
	for _, tc := range []struct{ body, endpoint, field, value string }{
		{`{"action":"rename","paths":["/Music/Song.mp3"],"target":"/Music/New.mp3"}`, "/files/batch_rename", "files_new_name[1]", "New.mp3"},
		{`{"action":"move","paths":["/Music/Song.mp3"],"target":"/Target"}`, "/files/move", "fid", "1"},
		{`{"action":"copy","paths":["/Music/Song.mp3"],"target":"/Target"}`, "/files/copy", "fid[0]", "1"},
		{`{"action":"delete","paths":["/Music/Song.mp3"]}`, "/rb/delete", "fid", "1"},
	} {
		w := request(s.Handler(), "POST", "/api/v1/cloud115/files/operations", tc.body, token)
		if w.Code != 200 {
			t.Fatal("operation failed", w.Code, w.Body.String())
		}
		last := mutations[len(mutations)-1]
		if last.path != tc.endpoint || last.form.Get(tc.field) != tc.value {
			t.Fatal("wrong reference request", last)
		}
		if tc.endpoint == "/files/copy" || tc.endpoint == "/files/move" {
			if last.form.Get("pid") != "20" {
				t.Fatal("wrong target directory")
			}
		}
	}
	w = request(s.Handler(), "GET", "/api/v1/files?root=strm", "", token)
	var listing struct{ Path string }
	if err := json.Unmarshal(w.Body.Bytes(), &listing); err != nil || w.Code != 200 || !strings.HasSuffix(listing.Path, "/cloud115/strm") {
		t.Fatal("local STRM shortcut unavailable", w.Code, w.Body.String())
	}
	if err := s.store.updateCloud(func(st *libraryState) error { st.Cloud.Cookie = ""; return nil }); err != nil {
		t.Fatal(err)
	}
	if w := request(s.Handler(), "GET", "/api/v1/cloud115/files", "", token); w.Code != 409 {
		t.Fatal("disconnected file manager accepted browsing")
	}
}
