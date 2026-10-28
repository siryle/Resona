package resona

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const qqArtistFixture = `{"code":0,"req_1":{"code":0,"data":{"body":{"singer":{"list":[
{"singerName":"Other","singerPic":"https://y.gtimg.cn/wrong.jpg"},
{"singerName":"周杰伦","singerPic":"http://y.gtimg.cn/artist.jpg"}]}}}}}`
const neteaseArtistFixture = `{"code":200,"result":{"artists":[
{"name":"Other","img1v1Url":"https://p1.music.126.net/wrong.jpg"},
{"name":"周杰伦","picUrl":"https://p1.music.126.net/poster.jpg","img1v1Url":"https://p1.music.126.net/artist.jpg"}]}}`

func artistJPEG(t *testing.T) []byte {
	t.Helper()
	var out bytes.Buffer
	if err := jpeg.Encode(&out, image.NewRGBA(image.Rect(0, 0, 8, 8)), nil); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func mockArtistArtwork(t *testing.T, qq, netease string, images map[string][]byte) (*Catalog, *atomic.Int32) {
	t.Helper()
	c := newCatalog()
	calls := new(atomic.Int32)
	c.Client.Transport = catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
			t.Error("credentials leaked to artwork provider")
		}
		var data []byte
		switch r.URL.Host {
		case "u.y.qq.com":
			var payload struct {
				Req struct {
					Param struct {
						Query string `json:"query"`
						Type  int    `json:"search_type"`
					} `json:"param"`
				} `json:"req_1"`
			}
			if err := json.Unmarshal([]byte(r.URL.Query().Get("data")), &payload); err != nil ||
				payload.Req.Param.Query != "周杰伦" || payload.Req.Param.Type != 1 {
				t.Error("incorrect QQ artist search", r.URL)
			}
			data = []byte(qq)
		case "music.163.com":
			if err := r.ParseForm(); err != nil || r.Method != "POST" ||
				r.Form.Get("type") != "100" || r.Form.Get("s") != "周杰伦" {
				t.Error("incorrect NetEase artist search", r.Form)
			}
			data = []byte(netease)
		default:
			data = images[r.URL.String()]
			if r.URL.Scheme != "https" || r.Header.Get("Referer") == "" {
				t.Error("image request lacks HTTPS or provider referer")
			}
		}
		if data == nil || len(data) == 0 {
			t.Errorf("unexpected artwork request: %s", r.URL)
		}
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header),
			Body: io.NopCloser(bytes.NewReader(data)), Request: r}, nil
	})
	return c, calls
}

func TestArtistArtworkAPIAndPersistentCache(t *testing.T) {
	s := testServer(t)
	track := addTestTrack(t, s)
	catalog, calls := mockArtistArtwork(t, qqArtistFixture, "", map[string][]byte{
		"https://y.gtimg.cn/artist.jpg": artistJPEG(t),
	})
	s.scanner.catalog = catalog
	token, h := loginToken(t, s), s.Handler()
	list := request(h, "GET", "/api/v1/artists?library=local", "", token)
	var result struct {
		Items []artistSummary `json:"items"`
	}
	if err := json.Unmarshal(list.Body.Bytes(), &result); err != nil || len(result.Items) != 1 {
		t.Fatal("artist list failed", list.Body.String(), err)
	}
	artist := result.Items[0]
	if artist.Name != track.Artist || artist.Tracks != 1 || artist.Artwork == "" || calls.Load() != 0 {
		t.Fatal("artist list should expose artwork without contacting providers", artist, calls.Load())
	}
	if w := request(h, "GET", artist.Artwork, "", ""); w.Code != 401 {
		t.Fatal("anonymous artwork accepted", w.Code)
	}
	for _, name := range []string{"", "Unknown Artist", "../../secret", "Missing"} {
		if w := request(h, "GET", "/api/v1/artists/avatar?name="+url.QueryEscape(name), "", token); w.Code != 404 {
			t.Fatal("invalid or unknown artist accepted", name, w.Code)
		}
	}
	if calls.Load() != 0 {
		t.Fatal("invalid artist triggered provider requests")
	}
	var wg sync.WaitGroup
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := request(h, "GET", artist.Artwork, "", token)
			if w.Code != 200 || w.Header().Get("Content-Type") != "image/jpeg" ||
				w.Header().Get("Cache-Control") != "private, max-age=86400" {
				t.Error("artwork not served", w.Code, w.Header(), w.Body.String())
				return
			}
			if _, err := jpeg.Decode(bytes.NewReader(w.Body.Bytes())); err != nil {
				t.Error("cached artwork is not JPEG", err)
			}
		}()
	}
	wg.Wait()
	if calls.Load() != 2 {
		t.Fatal("concurrent artwork requests should share one lookup and download", calls.Load())
	}
	reopened, err := NewServer(context.Background(), s.config)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	reopened.scanner.catalog = catalog
	if w := request(reopened.Handler(), "GET", artist.Artwork, "", loginToken(t, reopened)); w.Code != 200 || calls.Load() != 2 {
		t.Fatal("cached artist artwork did not survive restart", w.Code, calls.Load())
	}
}

func TestArtistArtworkFallbackAndDisabledSources(t *testing.T) {
	for _, tc := range []struct {
		name, qq string
		disabled []string
		want     int32
	}{
		{name: "no exact QQ match", qq: `{"code":0,"req_1":{"code":0,"data":{"body":{"singer":{"list":[{"singerName":"周杰伦.","singerPic":"https://y.gtimg.cn/wrong.jpg"}]}}}}}`, want: 3},
		{name: "QQ unavailable", qq: `{"code":500}`, want: 3},
		{name: "QQ disabled", disabled: []string{"qq"}, want: 2},
		{name: "invalid QQ image", qq: qqArtistFixture, want: 4},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := testServer(t)
			track := addTestTrack(t, s)
			catalog, calls := mockArtistArtwork(t, tc.qq, neteaseArtistFixture, map[string][]byte{
				"https://y.gtimg.cn/artist.jpg":                     []byte("not an image"),
				"https://p1.music.126.net/artist.jpg?param=500y500": artistJPEG(t),
			})
			s.scanner.catalog = catalog
			if err := s.store.update(func(st *libraryState) error {
				st.Sources.MetadataDisabled = tc.disabled
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			w := request(s.Handler(), "GET", artistArtworkURL(track.Artist), "", loginToken(t, s))
			if w.Code != 200 || calls.Load() != tc.want {
				t.Fatal("artist artwork fallback failed", w.Code, w.Body.String(), calls.Load())
			}
		})
	}
}

func TestArtistArtworkMissingCacheAndTransientErrors(t *testing.T) {
	for _, tc := range []struct {
		name, qq, netease string
		status            int
		cached            bool
	}{
		{name: "no match", qq: `{"code":0,"req_1":{"code":0}}`, netease: `{"code":200,"result":{"artists":[]}}`, status: 404, cached: true},
		{name: "upstream error", qq: `{"code":500}`, netease: `{"code":500}`, status: 502},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := testServer(t)
			track := addTestTrack(t, s)
			catalog, calls := mockArtistArtwork(t, tc.qq, tc.netease, nil)
			s.scanner.catalog = catalog
			h, token := s.Handler(), loginToken(t, s)
			for range 2 {
				w := request(h, "GET", artistArtworkURL(track.Artist), "", token)
				if w.Code != tc.status {
					t.Fatal("unexpected artwork error", w.Code, w.Body.String())
				}
			}
			if tc.cached {
				if calls.Load() != 2 {
					t.Fatal("missing artwork was not cached", calls.Load())
				}
				files, err := filepath.Glob(filepath.Join(s.config.DataDir, "artwork", "artists", "*.missing"))
				if err != nil || len(files) != 1 {
					t.Fatal("missing artwork cache not persisted", files, err)
				}
				expired := time.Now().Add(-7 * time.Hour)
				if err := os.Chtimes(files[0], expired, expired); err != nil {
					t.Fatal(err)
				}
				request(h, "GET", artistArtworkURL(track.Artist), "", token)
			}
			if calls.Load() != 4 {
				t.Fatal("expired misses and transient errors must retry", calls.Load())
			}
		})
	}
}

func TestArtistArtworkPriorityAndEnablingSources(t *testing.T) {
	s := testServer(t)
	track := addTestTrack(t, s)
	catalog, calls := mockArtistArtwork(t, "", neteaseArtistFixture, map[string][]byte{
		"https://p1.music.126.net/artist.jpg?param=500y500": artistJPEG(t),
	})
	s.scanner.catalog = catalog
	if err := s.store.update(func(st *libraryState) error {
		st.Sources.MetadataDisabled = []string{"qq", "netease"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	h, token := s.Handler(), loginToken(t, s)
	if w := request(h, "GET", artistArtworkURL(track.Artist), "", token); w.Code != 404 || calls.Load() != 0 {
		t.Fatal("disabled artist providers were contacted", w.Code, calls.Load())
	}
	if err := s.store.update(func(st *libraryState) error {
		st.Sources.MetadataDisabled = nil
		st.Sources.MetadataPriority = []string{"netease", "qq"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if w := request(h, "GET", artistArtworkURL(track.Artist), "", token); w.Code != 200 || calls.Load() != 2 {
		t.Fatal("enabled sources or source priority ignored", w.Code, calls.Load())
	}
}

func TestArtistArtworkDownloadValidation(t *testing.T) {
	for _, raw := range []string{
		"http://127.0.0.1/secret", "file:///etc/passwd", "https://y.gtimg.cn.evil.example/x",
		"https://y.gtimg.cn:443/x", "https://user:password@y.gtimg.cn/x", "https://music.126.net.evil.example/x",
	} {
		c := newCatalog()
		c.Client.Transport = catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
			t.Error("untrusted image URL requested", raw)
			return nil, io.EOF
		})
		if err := c.downloadArtistArtwork(context.Background(), "qq", raw, filepath.Join(t.TempDir(), "image.jpg")); err == nil {
			t.Error("invalid artwork URL accepted", raw)
		}
	}
	c := newCatalog()
	calls := 0
	c.Client.Transport = catalogRoundTripper(func(r *http.Request) (*http.Response, error) {
		calls++
		return &http.Response{StatusCode: http.StatusFound,
			Header: http.Header{"Location": {"https://127.0.0.1/secret"}},
			Body:   io.NopCloser(strings.NewReader("")), Request: r}, nil
	})
	if err := c.downloadArtistArtwork(context.Background(), "qq", "https://y.gtimg.cn/artist.jpg",
		filepath.Join(t.TempDir(), "image.jpg")); err == nil || calls != 1 {
		t.Fatal("untrusted image redirect followed", err, calls)
	}
	for _, tc := range []struct {
		name string
		data []byte
	}{
		{name: "oversized", data: bytes.Repeat([]byte("x"), (5<<20)+1)},
		{name: "invalid", data: []byte("<html>blocked</html>")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			catalog, _ := mockArtistArtwork(t, "", "", map[string][]byte{"https://y.gtimg.cn/artist.jpg": tc.data})
			path := filepath.Join(t.TempDir(), "image.jpg")
			if err := catalog.downloadArtistArtwork(context.Background(), "qq", "https://y.gtimg.cn/artist.jpg", path); err == nil {
				t.Fatal("invalid image accepted")
			}
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatal("invalid image left a cache entry", err)
			}
		})
	}
}

func TestCacheArtworkConversionAndValidation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "artwork", "avatar.jpg")
	var pngData bytes.Buffer
	if err := png.Encode(&pngData, image.NewRGBA(image.Rect(0, 0, 4, 4))); err != nil {
		t.Fatal(err)
	}
	if err := cacheArtwork(path, pngData.Bytes()); err != nil {
		t.Fatal("PNG artwork conversion failed", err)
	}
	cached, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := jpeg.Decode(bytes.NewReader(cached)); err != nil {
		t.Fatal("converted artwork is not JPEG", err)
	}
	var oversized bytes.Buffer
	if err := png.Encode(&oversized, image.NewRGBA(image.Rect(0, 0, 2001, 1))); err != nil {
		t.Fatal(err)
	}
	for _, data := range [][]byte{[]byte("invalid"), oversized.Bytes()} {
		if err := cacheArtwork(path, data); err == nil {
			t.Fatal("invalid artwork accepted")
		}
		current, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(current, cached) {
			t.Fatal("failed artwork update replaced existing cache", err)
		}
	}
	files, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(files) != 1 {
		t.Fatal("artwork conversion left temporary files", files, err)
	}
}
