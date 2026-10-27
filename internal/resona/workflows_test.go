package resona

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestDeleteJobHistory(t *testing.T) {
	s := testServer(t)
	track := addTestTrack(t, s)
	before, err := os.ReadFile(track.Path)
	if err != nil {
		t.Fatal(err)
	}
	for _, job := range []Job{{ID: "finished", State: "completed"}, {ID: "active", State: "running"}} {
		if err := s.store.putJob(job); err != nil {
			t.Fatal(err)
		}
	}
	h, token := s.Handler(), loginToken(t, s)
	for _, tc := range []struct {
		id, token string
		status    int
	}{{"finished", "", 401}, {"missing", token, 404}, {"active", token, 409}} {
		if w := request(h, "DELETE", "/api/v1/jobs/"+tc.id, "", tc.token); w.Code != tc.status {
			t.Fatal(tc, w.Code, w.Body.String())
		}
	}
	r := httptest.NewRequest("DELETE", "/api/v1/jobs/finished", nil)
	r.AddCookie(&http.Cookie{Name: "resona_session", Value: token})
	r.Header.Set("Origin", "https://other.example")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("cross-origin delete allowed", w.Code)
	}
	if w := request(h, "DELETE", "/api/v1/jobs/finished", "", token); w.Code != 204 {
		t.Fatal(w.Code, w.Body.String())
	}
	reopened, err := OpenStore(s.config.DataDir)
	if err != nil || len(reopened.Jobs()) != 1 || reopened.Jobs()[0].ID != "active" {
		t.Fatal("history deletion not persisted", err)
	}
	if current, ok := reopened.Track(track.ID); !ok || current.Title != track.Title {
		t.Fatal("deleting history changed music index")
	}
	after, err := os.ReadFile(track.Path)
	if err != nil || string(before) != string(after) {
		t.Fatal("deleting history changed audio", err)
	}
	if w := request(h, "DELETE", "/api/v1/jobs/finished", "", token); w.Code != 404 {
		t.Fatal("repeated delete resurrected job")
	}
}

func TestBulkDeleteJobHistory(t *testing.T) {
	s := testServer(t)
	track := addTestTrack(t, s)
	audio, _ := os.ReadFile(track.Path)
	for _, job := range []Job{{ID: "a", State: "completed"}, {ID: "b", State: "interrupted"}, {ID: "active", State: "running"}} {
		if err := s.store.putJob(job); err != nil {
			t.Fatal(err)
		}
	}
	h, token := s.Handler(), loginToken(t, s)
	for _, tc := range []struct {
		body, token string
		code        int
	}{
		{`{"all":true}`, "", 401}, {`{}`, token, 400}, {`{"all":true,"ids":["a"]}`, token, 400},
		{`{"ids":[""]}`, token, 400}, {`{"ids":["a","a"]}`, token, 400},
		{`{"ids":["a","missing"]}`, token, 404}, {`{"ids":["a","active"]}`, token, 409},
	} {
		w := request(h, "DELETE", "/api/v1/jobs", tc.body, tc.token)
		if w.Code != tc.code || len(s.store.Jobs()) != 3 {
			t.Fatal("non-atomic validation", tc, w.Code, w.Body.String())
		}
	}
	r := httptest.NewRequest("DELETE", "/api/v1/jobs", strings.NewReader(`{"all":true}`))
	r.Header.Set("Origin", "https://other.example")
	r.Header.Set("Content-Type", "application/json")
	r.AddCookie(&http.Cookie{Name: "resona_session", Value: token})
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("cross-origin batch deletion allowed", w.Code)
	}
	for _, tc := range []struct {
		body               string
		deleted, remaining int
	}{
		{`{"ids":["a"]}`, 1, 2}, {`{"all":true}`, 1, 1}, {`{"all":true}`, 0, 1},
	} {
		w := request(h, "DELETE", "/api/v1/jobs", tc.body, token)
		var result struct {
			Deleted int `json:"deleted"`
			Running int `json:"skipped_running"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || w.Code != 200 || result.Deleted != tc.deleted || len(s.store.Jobs()) != tc.remaining {
			t.Fatal(tc, w.Code, w.Body.String(), err)
		}
		if tc.body == `{"all":true}` && result.Running != 1 {
			t.Fatal("running task not retained", result)
		}
	}
	reopened, err := OpenStore(s.config.DataDir)
	if err != nil || len(reopened.Jobs()) != 1 || reopened.Jobs()[0].ID != "active" {
		t.Fatal("batch deletion not persisted", err)
	}
	if _, ok := s.store.Track(track.ID); !ok {
		t.Fatal("deleted music index")
	}
	if after, err := os.ReadFile(track.Path); err != nil || string(after) != string(audio) {
		t.Fatal("deleted music file", err)
	}
}

func TestMetadataPrioritySettings(t *testing.T) {
	s := testServer(t)
	h, token := s.Handler(), loginToken(t, s)
	settings := s.store.SourceSettings()
	settings.Metadata = "auto"
	settings.MetadataPriority[0], settings.MetadataPriority[1] = settings.MetadataPriority[1], settings.MetadataPriority[0]
	settings.MetadataDisabled = []string{"qq", "smart_tag"}
	for _, invalid := range []SourceSettings{
		{Metadata: "auto", Lyrics: "lrclib", MetadataPriority: []string{}},
		{Metadata: "auto", Lyrics: "lrclib", MetadataPriority: []string{"qq", "qq"}},
		{Metadata: "auto", Lyrics: "lrclib", MetadataDisabled: []string{"lrclib"}},
		{Metadata: "auto", Lyrics: "lrclib", MetadataDisabled: []string{"qq", "qq"}},
		{Metadata: "auto", Lyrics: "lrclib", MetadataDisabled: defaultMetadataPriority},
		{Metadata: "auto", Lyrics: "lrclib", MetadataDisabled: defaultMetadataPriority[:len(defaultMetadataPriority)-1]},
	} {
		raw, _ := json.Marshal(invalid)
		if w := request(h, "PUT", "/api/v1/sources", string(raw), token); w.Code != 400 {
			t.Fatal("invalid priority accepted", string(raw), w.Code)
		}
	}
	raw, _ := json.Marshal(settings)
	if w := request(h, "PUT", "/api/v1/sources", string(raw), token); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	// Old clients update defaults without resetting the new priority and disabled lists.
	if w := request(h, "PUT", "/api/v1/sources", `{"metadata":"qq","lyrics":"lrclib"}`, token); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	settings.Metadata = "qq"
	reopened, err := OpenStore(s.config.DataDir)
	if err != nil || !reflect.DeepEqual(reopened.SourceSettings(), settings) {
		t.Fatal("source settings not preserved", reopened, err)
	}
	copy := s.store.SourceSettings()
	copy.MetadataPriority[0], copy.MetadataDisabled[0] = "changed", "changed"
	if !reflect.DeepEqual(s.store.SourceSettings(), settings) {
		t.Fatal("source settings share mutable slices")
	}
}

type catalogRoundTripper func(*http.Request) (*http.Response, error)

func (f catalogRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestAutomaticMetadataPriorityAndDisabledSources(t *testing.T) {
	s := testServer(t)
	priority := append([]string{}, defaultMetadataPriority...)
	priority[0], priority[1] = priority[1], priority[0]
	for _, tc := range []struct {
		name, source, netease string
		disabled              []string
		want                  []string
		success               bool
	}{
		{"first success stops", "auto", catalogFixtures["https://music.163.com/api/search/get/web"], nil, []string{"music.163.com"}, true},
		{"empty falls back", "auto", `{"code":200,"result":{"songs":[]}}`, nil, []string{"music.163.com", "u.y.qq.com"}, true},
		{"upstream error falls back", "auto", `{"code":500}`, nil, []string{"music.163.com", "u.y.qq.com"}, true},
		{"wrong identity falls back", "auto", strings.ReplaceAll(catalogFixtures["https://music.163.com/api/search/get/web"], "Song", "Different"), nil, []string{"music.163.com", "u.y.qq.com"}, true},
		{"disabled is skipped", "auto", "", []string{"netease"}, []string{"u.y.qq.com"}, true},
		{"specific source has no fallback", "netease", `{"code":500}`, nil, []string{"music.163.com"}, false},
		{"disabled applies only to auto", "qq", "", []string{"qq"}, []string{"u.y.qq.com"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := s.store.update(func(st *libraryState) error {
				st.Sources = SourceSettings{Metadata: tc.source, MetadataPriority: priority, MetadataDisabled: tc.disabled}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			calls := []string{}
			c := newCatalog()
			c.Client.Transport = catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
				calls = append(calls, r.URL.Host)
				body := catalogFixtures[r.URL.Scheme+"://"+r.URL.Host+r.URL.Path]
				if r.URL.Host == "music.163.com" {
					body = tc.netease
				}
				if body == "" {
					t.Fatalf("unexpected provider request: %s", r.URL.Host)
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
			})
			s.scanner.catalog = c
			track := Track{Title: "Song", Artist: "Artist", Duration: 239, Genre: "Original"}
			before := track
			err := s.scanner.enrich(context.Background(), &track, tc.source)
			if (err == nil) != tc.success || !reflect.DeepEqual(calls, tc.want) {
				t.Fatal("wrong fallback behavior", calls, tc.want, track, err)
			}
			if !tc.success && !reflect.DeepEqual(before, track) {
				t.Fatal("failed source modified local metadata")
			}
			if tc.success && (track.Album != "Album" || track.Genre != "Original") {
				t.Fatal("local metadata not preserved", track)
			}
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			calls = nil
			if err := s.scanner.enrich(ctx, &track, "auto"); !errors.Is(err, context.Canceled) || len(calls) > 0 {
				t.Fatal("canceled scan contacted providers", err, calls)
			}
		})
	}
}

func TestChineseCatalogAndSmartRanking(t *testing.T) {
	s := testServer(t)
	responses := map[string]string{
		"https://c.musicapp.migu.cn/v1.0/content/search_all.do":   `{"code":"000000","songResultData":{"result":[{"copyrightId":"migu-id","name":"Song","singers":[{"name":"Artist"}],"albums":[{"name":"Album"}]}]}}`,
		"https://c.musicapp.migu.cn/v1.0/content/resourceinfo.do": `{"code":"000000","resource":[{"length":"00:03:59","trackNumber":"3","disc":"Disc 1"}]}`,
		"https://search.kuwo.cn/r.s":                              `{'abslist':[{'MUSICRID':'MUSIC_123','NAME':'Song','ARTIST':'Artist','ALBUM':'Album','DURATION':'239'}]}`,
	}
	for endpoint, body := range catalogFixtures {
		responses[endpoint] = body
	}
	for _, source := range []string{"migu", "kuwo"} {
		items, err := mockCatalog(t, responses).Search(context.Background(), source, "Song", "Artist")
		if err != nil || len(items) != 1 || items[0].Duration != 239 || items[0].Album != "Album" || items[0].Source != source {
			t.Fatal(source, items, err)
		}
		if source == "migu" && (items[0].Number != 3 || items[0].Disc != 1) {
			t.Fatal("Migu details missing", items)
		}
	}
	if err := s.store.update(func(st *libraryState) error {
		st.Sources.MetadataDisabled = []string{"kugou", "musicbrainz", "itunes", "migu", "kuwo"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	responses["https://u.y.qq.com/cgi-bin/musicu.fcg"] = strings.ReplaceAll(responses["https://u.y.qq.com/cgi-bin/musicu.fcg"], `"name":"Song"`, `"name":"Different"`)
	s.scanner.catalog = mockCatalog(t, responses)
	items, err := s.scanner.searchTrackCandidates(context.Background(), "smart_tag", Track{Title: "Song", Artist: "Artist", Album: "Album", Duration: 239})
	if err != nil || len(items) != 2 || items[0].Source != "netease" || items[0].Score != 100 {
		t.Fatal("smart source did not rank the correct identity first", items, err)
	}
	var parsed map[string]string
	if err := json.Unmarshal(kuwoJSON([]byte(`{'title':'Artist\'s "Song"','slash':'a\\b'}`)), &parsed); err != nil ||
		parsed["title"] != `Artist's "Song"` || parsed["slash"] != `a\b` {
		t.Fatal("quoted Kuwo response corrupted", parsed, err)
	}
}

func TestMiguPreservesCandidatesWhenOneDetailFails(t *testing.T) {
	c := newCatalog()
	c.Client.Transport = catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
		body := `{"code":"000000","songResultData":{"result":[{"copyrightId":"missing","name":"Song","singers":[{"name":"Artist"}]},{"copyrightId":"good","name":"Song","singers":[{"name":"Artist"}]}]}}`
		if r.URL.Path == "/v1.0/content/resourceinfo.do" {
			body = `{"code":"000000","resource":[{"length":"00:03:59","trackNumber":"3"}]}`
			if r.URL.Query().Get("copyrightId") == "missing" {
				body = `{"code":"000000","resource":[]}`
			}
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
	})
	items, err := c.Search(context.Background(), "migu", "Song", "Artist")
	if err != nil || len(items) != 1 || items[0].SourceID != "good" || items[0].Duration != 239 {
		t.Fatal("one unavailable recording discarded valid candidates", items, err)
	}
}
