package resona

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCloudFolderPickerCanonicalPaths(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	token := loginToken(t, s)
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		parent := r.URL.Query().Get("cid")
		parts := []any{map[string]string{"cid": "0", "name": "根目录"}}
		switch parent {
		case "10":
			parts = append(parts, map[string]string{"cid": "9", "name": "音乐"}, map[string]string{"cid": "10", "name": "中文 & Live"})
		case "11":
			parts = append(parts, map[string]string{"cid": "11", "name": "../错误路径"})
		case "12":
			parts = []any{map[string]string{"cid": "12", "name": "缺少祖先"}}
		case "13":
			parts = append(parts, map[string]string{"cid": "13", "name": "重复"}, map[string]string{"cid": "13", "name": "重复"})
		}
		jsonResponse(w, 200, map[string]any{"state": true, "cid": parent, "path": parts, "count": 2, "data": []any{
			map[string]string{"cid": "20", "pid": parent, "n": "子目录", "fc": "0"}, treeFile("21", parent, "歌曲.flac"),
		}})
	}))
	defer api.Close()
	s.cloud.webURL = api.URL
	for _, tc := range []struct{ id, path string }{{"0", "/"}, {"10", "/音乐/中文 & Live"}} {
		w := request(s.Handler(), "GET", "/api/v1/cloud115/folders?parent="+tc.id, "", token)
		var data struct {
			Parent, Path string
			Items        []struct{ ID, Name string }
			Breadcrumbs  []struct{ ID, Name string }
		}
		if err := json.Unmarshal(w.Body.Bytes(), &data); err != nil || w.Code != 200 {
			t.Fatal("folder listing failed", w.Code, w.Body.String(), err)
		}
		if data.Parent != tc.id || data.Path != tc.path || len(data.Items) != 1 || data.Items[0].ID != "20" ||
			data.Breadcrumbs[0].Name != "全部文件" || data.Breadcrumbs[len(data.Breadcrumbs)-1].ID != tc.id {
			t.Fatal("wrong path or folder filtering", w.Body.String())
		}
	}
	for _, id := range []string{"11", "12", "13"} {
		if w := request(s.Handler(), "GET", "/api/v1/cloud115/folders?parent="+id, "", token); w.Code != 502 {
			t.Fatal("invalid breadcrumbs accepted", id, w.Code, w.Body.String())
		}
	}
}
