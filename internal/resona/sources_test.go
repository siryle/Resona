package resona

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

var catalogFixtures = map[string]string{
	"https://u.y.qq.com/cgi-bin/musicu.fcg":                     `{"code":0,"req_1":{"code":0,"data":{"body":{"song":{"list":[{"mid":"qq-id","name":"Song","singer":[{"name":"Artist"}],"album":{"name":"Album"},"interval":239,"time_public":"2020-01-01","index_album":3}]}}}}}`,
	"https://music.163.com/api/search/get/web":                  `{"code":200,"result":{"songs":[{"id":123,"name":"Song","artists":[{"name":"Artist"}],"album":{"name":"Album","publishTime":1577836800000},"duration":239000}]}}`,
	"https://songsearch.kugou.com/song_search_v2":               `{"status":1,"data":{"lists":[{"SongName":"Song","SingerName":"Artist","AlbumName":"Album","FileHash":"hash","Duration":239}]}}`,
	"https://itunes.apple.com/search":                           `{"resultCount":1,"results":[{"trackId":123,"trackName":"Song","artistName":"Artist","collectionName":"Album","releaseDate":"2020-01-01","trackTimeMillis":239000,"trackNumber":3}]}`,
	"https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg": `{"code":0,"lyric":"[00:01.00]One &amp; two"}`,
	"https://music.163.com/api/song/lyric":                      `{"code":200,"lrc":{"lyric":"[00:01.00]One & two"}}`,
	"https://lyrics.kugou.com/search":                           `{"status":200,"candidates":[{"id":"wrong","accesskey":"bad","song":"Other","singer":"Artist","duration":239000},{"id":"lyric-id","accesskey":"key","song":"Song","singer":"Artist","duration":239000}]}`,
	"https://lyrics.kugou.com/download":                         `{"status":200,"content":"` + base64.StdEncoding.EncodeToString([]byte("[00:01.00]One & two")) + `"}`,
}

func mockCatalog(t *testing.T, responses map[string]string) *Catalog {
	t.Helper()
	c := newCatalog()
	fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
			t.Error("credentials sent to public provider")
		}
		endpoint := r.URL.Query().Get("fixture")
		if strings.Contains(endpoint, "get/web") {
			if r.Method != "POST" || r.ParseForm() != nil || r.Form.Get("s") == "" {
				t.Error("incorrect NetEase query", r.Method, r.Form)
			}
		}
		if strings.Contains(endpoint, "lyrics.kugou.com/download") &&
			(r.URL.Query().Get("id") != "lyric-id" || r.URL.Query().Get("accesskey") != "key") {
			t.Error("wrong lyric version downloaded")
		}
		body, ok := responses[endpoint]
		if !ok {
			t.Errorf("unexpected provider request: %s", endpoint)
			w.WriteHeader(500)
			return
		}
		io.WriteString(w, body)
	}))
	t.Cleanup(fixture.Close)
	c.Client = fixture.Client()
	c.Client.Transport = fixtureTransport{base: fixture.Client().Transport, url: fixture.URL}
	return c
}

type fixtureTransport struct {
	base http.RoundTripper
	url  string
}

func (f fixtureTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	copy := r.Clone(r.Context())
	u := *r.URL
	copy.URL = &u
	target, _ := http.NewRequest(r.Method, f.url, nil)
	endpoint := copy.URL.Scheme + "://" + copy.URL.Host + copy.URL.Path
	copy.URL.Scheme, copy.URL.Host = target.URL.Scheme, target.URL.Host
	q := copy.URL.Query()
	q.Set("fixture", endpoint)
	copy.URL.RawQuery = q.Encode()
	return f.base.RoundTrip(copy)
}

func TestCatalogMetadataAndLyrics(t *testing.T) {
	for _, source := range []string{"qq", "netease", "kugou", "itunes"} {
		t.Run(source, func(t *testing.T) {
			c := mockCatalog(t, catalogFixtures)
			items, err := c.Search(context.Background(), source, "Song", "Artist")
			if err != nil || len(items) != 1 {
				t.Fatal(items, err)
			}
			item := items[0]
			if item.Title != "Song" || item.Artist != "Artist" || item.Album != "Album" ||
				item.Duration != 239 || item.Source != source || item.SourceID == "" {
				t.Fatal("incorrect mapping", item)
			}
			if source == "itunes" {
				return
			}
			lyric, err := c.FetchLyrics(context.Background(), source, Track{Title: "Song", Artist: "Artist", Album: "Album", Duration: 239})
			if err != nil || lyric.Text != "[00:01.00]One & two" || !lyric.Synced || lyric.Source != source {
				t.Fatal(lyric, err)
			}
			for _, track := range []Track{
				{Title: "Other", Artist: "Artist", Duration: 239},
				{Title: "Song", Artist: "Other", Duration: 239},
				{Title: "Song", Artist: "Artist", Album: "Live", Duration: 239},
				{Title: "Song", Artist: "Artist", Duration: 260},
			} {
				if _, err := c.FetchLyrics(context.Background(), source, track); !errors.Is(err, errNoLyrics) {
					t.Fatal("mismatched identity accepted", track, err)
				}
			}
		})
	}
}

func TestSourceSettingsValidationAndPersistence(t *testing.T) {
	s := testServer(t)
	h, token := s.Handler(), loginToken(t, s)
	for _, method := range []string{"GET", "PUT"} {
		if w := request(h, method, "/api/v1/sources", `{}`, ""); w.Code != 401 {
			t.Fatal("unauthenticated sources accepted", w.Code)
		}
	}
	if p := s.store.SourceSettings(); p.Metadata != "musicbrainz" || p.Lyrics != "lrclib" || !reflect.DeepEqual(p.MetadataPriority, defaultMetadataPriority) {
		t.Fatal("changed legacy defaults")
	}
	for _, invalid := range []string{
		`{"metadata":"lrclib","lyrics":"qq"}`,
		`{"metadata":"qq","lyrics":"itunes"}`,
		`{"metadata":"missing","lyrics":"auto"}`,
		`{"metadata":"qq","lyrics":"qq","url":"http://localhost"}`,
	} {
		if w := request(h, "PUT", "/api/v1/sources", invalid, token); w.Code != 400 {
			t.Fatal("invalid setting accepted", w.Code, w.Body.String())
		}
	}
	if w := request(h, "PUT", "/api/v1/sources", `{"metadata":"qq","lyrics":"auto"}`, token); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if err := s.store.putJob(Job{ID: "preserve-settings", Errors: []string{}}); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenStore(s.config.DataDir)
	if err != nil || reopened.SourceSettings().Metadata != "qq" || reopened.SourceSettings().Lyrics != "auto" {
		t.Fatal("settings not preserved", err)
	}
	track := addTestTrack(t, s)
	if w := request(h, "GET", "/api/v1/tracks/"+track.ID+"/matches?source=lrclib", "", token); w.Code != 400 {
		t.Fatal("invalid metadata source accepted", w.Code)
	}
	if w := request(h, "POST", "/api/v1/tracks/"+track.ID+"/lyrics/scrape", `{"source":"itunes"}`, token); w.Code != 400 {
		t.Fatal("invalid lyric source accepted", w.Code)
	}
}

func TestAutomaticLyricsFallbackAndRateLimit(t *testing.T) {
	s := testServer(t)
	s.scanner.catalog = mockCatalog(t, catalogFixtures)
	unavailable := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(503) }))
	defer unavailable.Close()
	s.scanner.lyricProvider = &LyricsProvider{Client: unavailable.Client(), Endpoint: unavailable.URL}
	lyric, err := s.scanner.fetchLyrics(context.Background(), "auto", Track{Title: "Song", Artist: "Artist", Album: "Album", Duration: 239})
	if err != nil || lyric.Source != "qq" {
		t.Fatal("fallback failed", lyric, err)
	}
	c := newCatalog()
	c.Endpoints = map[string]string{"https://itunes.apple.com/search": unavailable.URL}
	c.Client = unavailable.Client()
	if _, err := c.Search(context.Background(), "itunes", "Song", "Artist"); !errors.Is(err, errLyricsBusy) {
		t.Fatal("rate limit ignored", err)
	}
	if c.retryAfter() < 59 {
		t.Fatal("retry delay missing")
	}
}

func TestAutomaticEnrichmentPreservesTags(t *testing.T) {
	s := testServer(t)
	s.scanner.catalog = mockCatalog(t, catalogFixtures)
	track := Track{Title: "Song", Artist: "Artist", Duration: 239, Genre: "Original"}
	if err := s.scanner.enrich(context.Background(), &track, "auto"); err != nil {
		t.Fatal(err)
	}
	if track.Album != "Album" || track.Year != "2020" || track.Genre != "Original" || track.MetadataSource != "qq" {
		t.Fatal("incorrect enrichment", track)
	}
	for source, payload := range map[string]string{"qq": `{"code":400}`, "netease": `{"code":500}`, "kugou": `{"status":0}`} {
		copy := map[string]string{}
		for endpoint := range catalogFixtures {
			copy[endpoint] = payload
		}
		c := mockCatalog(t, copy)
		if _, err := c.Search(context.Background(), source, "Song", "Artist"); err == nil {
			t.Fatal("upstream error accepted", source)
		}
	}
	data, _ := json.Marshal(track)
	if strings.Contains(string(data), "tag_lyrics") {
		t.Fatal("embedded text exposed in track JSON")
	}
}
