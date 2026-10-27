package resona

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func seedCloud(t *testing.T, s *Server) {
	t.Helper()
	if err := s.store.update(func(st *libraryState) error {
		st.Cloud = CloudState{Settings: CloudSettings{RootID: "0", BaseURL: "https://music.example.com", Enabled: true},
			Account: "42", Cookie: "UID=42_A1; CID=private-cid; SEID=private-seid", Items: map[string]CloudItem{}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func cloudResponse(w http.ResponseWriter, data any) {
	jsonResponse(w, 200, map[string]any{"state": true, "data": data})
}

func TestCloudPreprobePublicationAndLibraryBoundaries(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "UID=42_A1; CID=private-cid; SEID=private-seid" || r.Header.Get("Authorization") != "" {
			t.Error("missing upstream authorization")
		}
		jsonResponse(w, 200, map[string]any{"state": 1, "cid": "0", "path": []any{map[string]any{"cid": "0"}}, "count": "1", "data": []any{
			map[string]any{"fid": 77, "cid": 0, "fn": "Artist - Song.flac", "fc": 1, "pc": "abcdefghijklmnopq", "sha1": strings.Repeat("A", 40), "fs": "100"},
		}})
	}))
	defer api.Close()
	s.cloud.apiURL, s.cloud.webURL = api.URL, api.URL
	id := cloudTrackID("42", "77")
	if err := s.store.update(func(st *libraryState) error {
		st.Tracks["local"] = DiskTrack{Track: Track{ID: "local", Title: "Local", Artist: "Artist", AlbumArtist: "Artist", Album: "Album"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	started, release := make(chan struct{}), make(chan struct{})
	s.cloud.probe = func(ctx context.Context, item CloudItem) (Track, error) {
		if item.TrackID != id {
			t.Error("unstable cloud ID")
		}
		if _, err := os.Stat(s.cloud.strmPath(item)); err != nil {
			t.Error("STRM was not generated before probing", err)
		}
		close(started)
		<-release
		return Track{Title: "Song", Artist: "Artist", AlbumArtist: "Artist", Album: "Album", Duration: 120,
			Format: "flac", TagLyrics: "[00:01.00]Embedded line"}, nil
	}
	token := loginToken(t, s)
	if w := request(s.Handler(), "POST", "/api/v1/cloud115/sync", "{}", token); w.Code != 202 {
		t.Fatalf("sync: %d %s", w.Code, w.Body.String())
	}
	s.cloud.wg.Wait()
	if _, exists := s.store.Track(id); !exists {
		t.Fatal("generation did not refresh cloud library")
	}
	select {
	case <-started:
		t.Fatal("generation unexpectedly started a probe")
	default:
	}
	if w := request(s.Handler(), "POST", "/api/v1/cloud115/probe", "{}", token); w.Code != 202 {
		t.Fatalf("probe: %d %s", w.Code, w.Body.String())
	}
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("background probe did not start")
	}
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
		s.cloud.wg.Wait()
	}()
	w := request(s.Handler(), "GET", "/api/v1/tracks?library=cloud", "", token)
	if !strings.Contains(w.Body.String(), `"total":1`) || !strings.Contains(w.Body.String(), `"metadata_source":"filename"`) {
		t.Fatal("basic cloud track missing during probing", w.Body.String())
	}
	w = request(s.Handler(), "GET", "/api/v1/cloud115", "", token)
	if strings.Contains(w.Body.String(), "private-") || !strings.Contains(w.Body.String(), `"probing":1`) {
		t.Fatal("secrets exposed or status unavailable during probing", w.Body.String())
	}
	close(release)
	s.cloud.wg.Wait()
	w = request(s.Handler(), "GET", "/api/v1/tracks?library=cloud", "", token)
	if !strings.Contains(w.Body.String(), `"total":1`) || !strings.Contains(w.Body.String(), `"hash_algorithm":"sha1"`) || !strings.Contains(w.Body.String(), strings.Repeat("a", 40)) {
		t.Fatal("ready track or content digest missing", w.Body.String())
	}
	w = request(s.Handler(), "GET", "/api/v1/tracks?library=local", "", token)
	if !strings.Contains(w.Body.String(), `"title":"Local"`) || strings.Contains(w.Body.String(), `"title":"Song"`) {
		t.Fatal("local/cloud scopes mixed", w.Body.String())
	}
	localAlbum := albumID(Track{AlbumArtist: "Artist", Album: "Album", Library: "local"})
	cloudAlbum := albumID(Track{AlbumArtist: "Artist", Album: "Album", Library: "cloud"})
	if localAlbum == cloudAlbum {
		t.Fatal("album identities collide across libraries")
	}
	for _, endpoint := range []string{"albums", "artists", "system"} {
		w = request(s.Handler(), "GET", "/api/v1/"+endpoint+"?library=cloud", "", token)
		if w.Code != 200 {
			t.Fatalf("%s: %s", endpoint, w.Body.String())
		}
	}
	s.cloud.probe = func(context.Context, CloudItem) (Track, error) {
		t.Error("client read triggered probing")
		return Track{}, fmt.Errorf("unexpected probe")
	}
	if w = request(s.Handler(), "GET", "/api/v1/tracks/"+id+"/lyrics", "", token); w.Code != 200 || !strings.Contains(w.Body.String(), "Embedded line") {
		t.Fatal("preprobed lyrics unavailable", w.Code, w.Body.String())
	}
	if w = request(s.Handler(), "POST", "/api/v1/tracks/"+id+"/lyrics/embed", "{}", token); w.Code != 415 {
		t.Fatal("remote audio permitted tag writes", w.Code)
	}
	item := s.cloud.snapshot().Items[id]
	content, err := os.ReadFile(s.cloud.strmPath(item))
	if err != nil || string(content) != "https://music.example.com/api/v1/tracks/"+id+"/stream\n" {
		t.Fatalf("bad STRM: %s %v", content, err)
	}
	reopened, err := OpenStore(s.config.DataDir)
	if err != nil || reopened.state.Cloud.Items[id].State != "ready" || reopened.state.Tracks[id].Remote == nil {
		t.Fatal("cloud index did not survive reopening", err)
	}
}

func TestCloudRedirectCacheRefreshAndSecrets(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	file := RemoteFile{Account: "42", FileID: "7", PickCode: "abcdefghijklmnopq", SHA1: strings.Repeat("a", 40)}
	id := cloudTrackID("42", "7")
	if err := s.store.update(func(st *libraryState) error {
		st.Tracks[id] = DiskTrack{Track: Track{ID: id, Title: "Logged Song", Artist: "Logged Artist", Format: "mp3"}, Remote: &file}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	key := cloudTestCipher(t)
	var calls atomic.Int32
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		cloudDownloadResponse(t, w, r, key, "7", "https://cdnfhnfile.115cdn.net:443/private-cdn-path.mp3?sign=private-cdn-signature&t="+fmt.Sprint(time.Now().Add(time.Hour).Unix()))
	}))
	defer api.Close()
	s.cloud.apiURL, s.cloud.webURL = api.URL, api.URL
	token := loginToken(t, s)
	makeRequest := func(ua, suffix string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "/api/v1/tracks/"+id+"/stream"+suffix, nil)
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("User-Agent", ua)
		r.Header.Set("Range", "bytes=10-20")
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, r)
		return w
	}
	var wg sync.WaitGroup
	for range 5 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := makeRequest("Player-A", "")
			if w.Code != 302 || !strings.HasPrefix(w.Header().Get("Location"), "https://cdnfhnfile.115cdn.net:443/") || w.Header().Get("Cache-Control") != "no-store" {
				t.Error("not a protected, uncached redirect", w.Code)
			}
		}()
	}
	wg.Wait()
	if calls.Load() != 1 {
		t.Fatal("concurrent link requests were not merged", calls.Load())
	}
	makeRequest("Player-B", "")
	makeRequest("Player-A", "?refresh=1")
	if calls.Load() != 3 {
		t.Fatal("UA isolation or forced refresh failed", calls.Load())
	}
	if w := request(s.Handler(), "GET", "/api/v1/tracks/"+id+"/stream", "", ""); w.Code != 401 {
		t.Fatal("anonymous redirect exposed")
	}
	if w := request(s.Handler(), "POST", "/api/v1/cloud115/disconnect", "{}", token); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	if w := makeRequest("Player-A", ""); w.Code != 503 {
		t.Fatal("disconnected source still plays", w.Code)
	}
	logs := request(s.Handler(), "GET", "/api/v1/logs?category=playback", "", token)
	var result struct {
		Items  []LogEntry
		Counts map[string]int
	}
	if err := json.Unmarshal(logs.Body.Bytes(), &result); logs.Code != 200 || err != nil || len(result.Items) != 8 ||
		result.Counts["INFO"] != 7 || result.Counts["WARN"] != 1 {
		t.Fatal("redirects, cached redirects or unavailable playback were not logged", logs.Body.String(), err)
	}
	for _, expected := range []string{"Logged Song", "Logged Artist", "status=302", "status=503", "method=GET", "refresh=true", "host=cdnfhnfile.115cdn.net", "elapsed_ms="} {
		if !strings.Contains(logs.Body.String(), expected) {
			t.Fatal("missing playback log detail", expected)
		}
	}
	reopened, err := openLogBook(s.config.DataDir)
	if err != nil {
		t.Fatal(err)
	}
	persisted := 0
	for _, entry := range reopened.entries {
		if entry.Category == "playback" {
			persisted++
		}
	}
	if persisted != 8 {
		t.Fatal("playback logs did not survive restart", persisted)
	}
	for _, secret := range []string{"private-cdn-path", "private-cdn-signature", "private-cid", "private-seid", file.PickCode, token} {
		if strings.Contains(logs.Body.String(), secret) || strings.Contains(string(mustReadFile(t, reopened.path)), secret) {
			t.Fatal("playback log leaked credentials or temporary link", secret)
		}
	}
}

func TestCloudCookieQRCodeLogin(t *testing.T) {
	s := testServer(t)
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if r.Header.Get("Authorization") != "" || r.Form.Get("client_id") != "" {
			t.Error("Open API authentication used")
		}
		switch r.URL.Path {
		case "/api/1.0/web/1.0/token/":
			if r.Method != "GET" || r.Header.Get("Cookie") != "" {
				t.Error("invalid QR token request")
			}
			cloudResponse(w, map[string]any{"uid": "qr-uid", "time": 1, "sign": "private-sign", "qrcode": "http://115.com/scan/dg-qr-uid"})
		case "/get/status/":
			if r.Form.Get("uid") != "qr-uid" || r.Form.Get("sign") != "private-sign" {
				t.Error("invalid QR polling parameters")
			}
			cloudResponse(w, map[string]any{"status": 2})
		case "/app/1.0/alipaymini/1.0/login/qrcode/":
			if r.Method != "POST" || r.Form.Get("account") != "qr-uid" {
				t.Error("invalid QR login request")
			}
			cloudResponse(w, map[string]any{"cookie": map[string]string{"UID": "42_A1", "CID": "new-private-cid", "SEID": "new-private-seid", "KID": "new-private-kid"}})
		case "/":
			if r.Form.Get("ct") != "ajax" || r.Form.Get("ac") != "nav" || !strings.Contains(r.Header.Get("Cookie"), "CID=new-private-cid") {
				t.Error("Cookie was not used to verify the account")
			}
			cloudResponse(w, map[string]any{"user_id": 42, "user_name": "My Account"})
		case "/files":
			if !strings.Contains(r.Header.Get("Cookie"), "KID=new-private-kid") {
				t.Error("saved Cookie not used")
			}
			jsonResponse(w, 200, map[string]any{"state": true, "cid": "0", "path": []any{map[string]any{"cid": "0"}}, "count": 0, "data": []any{}})
		default:
			t.Error("unexpected upstream endpoint", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer api.Close()
	s.cloud.apiURL, s.cloud.webURL, s.cloud.userURL, s.cloud.qrURL = api.URL, api.URL, api.URL, api.URL
	token := loginToken(t, s)
	for _, path := range []string{"/api/v1/cloud115", "/api/v1/cloud115/auth", "/api/v1/cloud115/auth/qr", "/api/v1/cloud115/folders"} {
		if w := request(s.Handler(), "GET", path, "", ""); w.Code != 401 {
			t.Fatal("cloud endpoint not protected", path)
		}
	}
	if w := request(s.Handler(), "POST", "/api/v1/cloud115/auth", "{}", token); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if w := request(s.Handler(), "GET", "/api/v1/cloud115/auth/qr", "", token); w.Code != 200 || !strings.HasPrefix(w.Body.String(), "\x89PNG") {
		t.Fatal("local QR rendering failed")
	}
	if w := request(s.Handler(), "GET", "/api/v1/cloud115/auth", "", token); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if _, err := s.cloud.list(context.Background(), "0"); err != nil {
		t.Fatal(err)
	}
	w := request(s.Handler(), "GET", "/api/v1/cloud115", "", token)
	if strings.Contains(w.Body.String(), "cookie") || strings.Contains(w.Body.String(), "private") || strings.Contains(w.Body.String(), "client_id") || !strings.Contains(w.Body.String(), `"connected":true`) {
		t.Fatal("status leaks credentials or application ID", w.Body.String())
	}
	reopened, err := OpenStore(s.config.DataDir)
	if err != nil || !strings.Contains(reopened.state.Cloud.Cookie, "KID=new-private-kid") {
		t.Fatal("Cookie did not survive reopening", err)
	}
	info, err := os.Stat(s.store.path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("credentials are not stored privately")
	}
}

func TestCloudCookieValidationAndExpiry(t *testing.T) {
	for _, values := range []map[string]string{
		{"UID": "42_A1", "CID": "a"},
		{"UID": "bad_A1", "CID": "a", "SEID": "b"},
		{"UID": "42_A1", "CID": "a; evil=b", "SEID": "b"},
		{"UID": "42_A1", "CID": "a", "SEID": "b\r\nAuthorization: secret"},
	} {
		if _, _, err := cloudCookie(values); err == nil {
			t.Fatal("invalid Cookie accepted")
		}
	}
	s := testServer(t)
	seedCloud(t, s)
	file := RemoteFile{Account: "42", FileID: "7", PickCode: "abcdefghijklmnopq"}
	id := cloudTrackID(file.Account, file.FileID)
	if err := s.store.update(func(st *libraryState) error {
		st.Tracks[id] = DiskTrack{Track: Track{ID: id, Title: "Kept Song", Favorite: true}, Remote: &file}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jsonResponse(w, 200, map[string]any{"state": false, "errno": 99, "error": "UID=private-do-not-log"})
	}))
	defer api.Close()
	s.cloud.apiURL, s.cloud.webURL = api.URL, api.URL
	if _, err := s.cloud.list(context.Background(), "0"); err != errCloudAuth {
		t.Fatal("expired Cookie was not detected", err)
	}
	if s.cloud.snapshot().Cookie != "" {
		t.Fatal("expired Cookie not cleared")
	}
	track, ok := s.store.Track(id)
	if !ok || !track.Unavailable || !track.Favorite {
		t.Fatal("expiry lost music or did not mark it unavailable")
	}
	if _, err := s.cloud.downloadURL(context.Background(), file, "Player"); err == nil {
		t.Fatal("expired source returned a cached link")
	}
}

func TestCloudQRCodeFailuresPreserveConnection(t *testing.T) {
	for _, scenario := range []string{"expired", "cancelled", "invalid-cookie", "wrong-account"} {
		t.Run(scenario, func(t *testing.T) {
			s := testServer(t)
			seedCloud(t, s)
			original := s.cloud.snapshot()
			s.cloud.auth = cloudAuth{UID: "qr-uid", Time: "1", Sign: "sign", ClientType: "alipaymini", Expires: time.Now().Add(time.Minute)}
			if scenario == "expired" {
				s.cloud.auth.Expires = time.Now().Add(-time.Minute)
			}
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/get/status/":
					status := 2
					if scenario == "cancelled" {
						status = -2
					}
					cloudResponse(w, map[string]any{"status": status})
				case "/app/1.0/alipaymini/1.0/login/qrcode/":
					values := map[string]string{"UID": "43_A1", "CID": "new-cid", "SEID": "new-seid"}
					if scenario == "invalid-cookie" {
						delete(values, "SEID")
					}
					cloudResponse(w, map[string]any{"cookie": values})
				case "/":
					cloudResponse(w, map[string]any{"user_id": 99, "user_name": "Wrong Account"})
				default:
					t.Error("unexpected login request", r.URL.Path)
				}
			}))
			defer api.Close()
			s.cloud.qrURL, s.cloud.userURL = api.URL, api.URL
			w := request(s.Handler(), "GET", "/api/v1/cloud115/auth", "", loginToken(t, s))
			want := 502
			if scenario == "expired" {
				want = 410
			} else if scenario == "cancelled" {
				want = 200
				if s.cloud.auth.UID != "" || !strings.Contains(w.Body.String(), `"status":-2`) {
					t.Fatal("cancelled QR session was not cleared")
				}
			}
			if w.Code != want {
				t.Fatal(w.Code, w.Body.String())
			}
			current := s.cloud.snapshot()
			if current.Cookie != original.Cookie || current.Account != original.Account {
				t.Fatal("failed login overwrote the existing connection")
			}
		})
	}
}

func TestCloudQRCodeLoginDevices(t *testing.T) {
	for _, device := range []string{"alipaymini", "wechatmini", "115android", "115ios", "web", "115ipad", "tv"} {
		t.Run(device, func(t *testing.T) {
			s := testServer(t)
			var tokens, logins atomic.Int32
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/api/1.0/web/1.0/token/":
					cloudResponse(w, map[string]any{"uid": fmt.Sprint(tokens.Add(1)), "time": 1, "sign": "private-sign"})
				case "/get/status/":
					if r.URL.Query().Get("uid") != "2" {
						t.Error("refresh did not replace the QR session")
					}
					cloudResponse(w, map[string]any{"status": 2})
				case "/app/1.0/" + device + "/1.0/login/qrcode/":
					logins.Add(1)
					cloudResponse(w, map[string]any{"cookie": map[string]string{"UID": "42_A1", "CID": "cid", "SEID": "seid"}})
				case "/":
					cloudResponse(w, map[string]any{"user_id": 42, "user_name": "Account"})
				default:
					t.Error("wrong device endpoint", r.URL.Path)
					w.WriteHeader(404)
				}
			}))
			defer api.Close()
			s.cloud.qrURL, s.cloud.userURL = api.URL, api.URL
			token := loginToken(t, s)
			for range 2 {
				body := fmt.Sprintf(`{"client_type":%q}`, device)
				w := request(s.Handler(), "POST", "/api/v1/cloud115/auth", body, token)
				if w.Code != 200 || !strings.Contains(w.Body.String(), `"client_type":"`+device+`"`) || s.cloud.auth.ClientType != device {
					t.Fatal("QR device not retained", w.Code, w.Body.String())
				}
			}
			w := request(s.Handler(), "POST", "/api/v1/cloud115/auth", `{"client_type":"../invalid"}`, token)
			if w.Code != 400 || tokens.Load() != 2 || s.cloud.auth.ClientType != device {
				t.Fatal("invalid device modified the current QR session")
			}
			// A polling parameter cannot change the device selected for the session.
			w = request(s.Handler(), "GET", "/api/v1/cloud115/auth?client_type=attacker", "", token)
			if w.Code != 200 || logins.Load() != 1 || s.cloud.snapshot().Cookie == "" {
				t.Fatal("selected-device login failed", w.Code, w.Body.String())
			}
		})
	}
}

func TestCloudQRCodeLongPollAllowsRefresh(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	if s.cloud.client.Timeout < 35*time.Second {
		t.Fatal("HTTP timeout is shorter than the 115 status long poll")
	}
	s.cloud.auth = cloudAuth{UID: "old-qr", Time: "1", Sign: "sign", ClientType: "alipaymini", Expires: time.Now().Add(time.Minute)}
	started, release := make(chan struct{}), make(chan struct{})
	var logins atomic.Int32
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/get/status/":
			close(started)
			<-release
			cloudResponse(w, map[string]any{"status": 2})
		case "/api/1.0/web/1.0/token/":
			cloudResponse(w, map[string]any{"uid": "new-qr", "time": 1, "sign": "sign"})
		default:
			logins.Add(1)
			w.WriteHeader(500)
		}
	}))
	defer api.Close()
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	s.cloud.qrURL = api.URL
	token := loginToken(t, s)
	polled := make(chan *httptest.ResponseRecorder, 1)
	go func() { polled <- request(s.Handler(), "GET", "/api/v1/cloud115/auth", "", token) }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("upstream poll did not start")
	}
	refreshed := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		refreshed <- request(s.Handler(), "POST", "/api/v1/cloud115/auth", `{"client_type":"tv"}`, token)
	}()
	select {
	case w := <-refreshed:
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body.String())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("long poll blocked QR refresh")
	}
	close(release)
	if w := <-polled; w.Code != 409 || logins.Load() != 0 || s.cloud.auth.ClientType != "tv" || s.cloud.auth.UID != "new-qr" {
		t.Fatal("stale confirmed poll changed the refreshed session", w.Code)
	}
}

func TestCloudQRCodeIdleLongPollResponse(t *testing.T) {
	s := testServer(t)
	s.cloud.auth = cloudAuth{UID: "qr", ClientType: "alipaymini", Time: "1", Sign: "sign", Expires: time.Now().Add(time.Minute)}
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Actual idle status response after the upstream's 30-second wait.
		jsonResponse(w, 200, map[string]any{"state": 1, "code": 0, "data": map[string]any{}})
	}))
	defer api.Close()
	s.cloud.qrURL = api.URL
	w := request(s.Handler(), "GET", "/api/v1/cloud115/auth", "", loginToken(t, s))
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"status":0`) || s.cloud.auth.UID != "qr" {
		t.Fatal("idle long poll was not treated as waiting", w.Code, w.Body.String())
	}
}

func TestCloudOpenAPIMigrationPreservesLibrary(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	id := cloudTrackID("42", "7")
	if err := s.store.update(func(st *libraryState) error {
		st.Tracks[id] = DiskTrack{Track: Track{ID: id, Title: "Kept Song", Favorite: true}, Remote: &RemoteFile{Account: "42", FileID: "7"}}
		st.Cloud.Items[id] = CloudItem{TrackID: id, State: "ready"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(s.config.DataDir, "library.json")
	data, _ := json.Marshal(s.store.state)
	var legacy map[string]any
	if err := json.Unmarshal(data, &legacy); err != nil {
		t.Fatal(err)
	}
	cloud := legacy["cloud115"].(map[string]any)
	delete(cloud, "cookie")
	cloud["access_token"], cloud["refresh_token"] = "legacy-private-access", "legacy-private-refresh"
	cloud["settings"].(map[string]any)["client_id"] = "123"
	data, _ = json.Marshal(legacy)
	if err := s.store.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(s.store.path); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(s.config.DataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	track, ok := store.Track(id)
	if !ok || !track.Unavailable || !track.Favorite || store.state.Cloud.Items[id].State != "ready" || store.state.Cloud.Account != "42" || store.state.Cloud.Cookie != "" {
		t.Fatal("migration lost indexed music or reused Open API credentials")
	}
	if err := store.db.QueryRow("SELECT data FROM settings WHERE key='cloud'").Scan(&data); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "legacy-private") || strings.Contains(string(data), "client_id") {
		t.Fatal("legacy credentials were not removed")
	}
}

func TestCloudRejectsCookieBoundOrWrongDownload(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	key := cloudTestCipher(t)
	for _, scenario := range []struct{ id, link string }{
		{"7", "https://fscdn.115.com/song.flac?f=3"},
		{"8", "https://fscdn.115.com/song.flac?f=1"},
		{"7", "https://attacker.invalid/song.flac"},
	} {
		api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			cloudDownloadResponse(t, w, r, key, scenario.id, scenario.link)
		}))
		s.cloud.apiURL, s.cloud.webURL = api.URL, api.URL
		_, err := s.cloud.downloadURL(context.Background(), RemoteFile{Account: "42", FileID: "7", PickCode: "abcdefghijklmnopq"}, "Player")
		api.Close()
		if err == nil {
			t.Fatal("unsafe or incorrect download accepted", scenario)
		}
	}
}

func TestCloudFailedProbeResumeAndIncompleteSync(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	item := CloudItem{RemoteFile: RemoteFile{Account: "42", FileID: "8"}, TrackID: cloudTrackID("42", "8"), State: "probing", Name: "Song.mp3"}
	if err := s.store.update(func(st *libraryState) error { st.Cloud.Items[item.TrackID] = item; return nil }); err != nil {
		t.Fatal(err)
	}
	s.cloud.probe = func(context.Context, CloudItem) (Track, error) { return Track{}, fmt.Errorf("temporary failure") }
	if err := s.cloud.start("resume", ""); err != nil {
		t.Fatal(err)
	}
	s.cloud.wg.Wait()
	if _, exists := s.store.Track(item.TrackID); exists || s.cloud.snapshot().Items[item.TrackID].State != "failed" {
		t.Fatal("failed probe was published or not recorded")
	}
	s.cloud.probe = func(context.Context, CloudItem) (Track, error) {
		return Track{Title: "Recovered", Duration: 1, Format: "mp3"}, nil
	}
	if err := s.cloud.start("retry", ""); err != nil {
		t.Fatal(err)
	}
	s.cloud.wg.Wait()
	if _, exists := s.store.Track(item.TrackID); !exists {
		t.Fatal("retry did not publish recovered track")
	}
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jsonResponse(w, 200, map[string]any{"state": true, "cid": "0", "path": []any{map[string]any{"cid": "0"}}, "count": 1, "data": []any{}})
	}))
	defer api.Close()
	s.cloud.apiURL, s.cloud.webURL = api.URL, api.URL
	if err := s.cloud.generate(context.Background()); err == nil {
		t.Fatal("incomplete pagination accepted")
	}
	track, _ := s.store.Track(item.TrackID)
	if track.Unavailable || s.cloud.snapshot().Items[item.TrackID].State != "ready" {
		t.Fatal("partial traversal removed existing music")
	}
}

func TestRemoteTagProbeReadsHTTPAudioAndKeepsOriginalFormat(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("requires ffmpeg")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "song.mp3")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "1",
		"-metadata", "title=Remote Title", "-metadata", "artist=Remote Artist", "-metadata", "album=Remote Album",
		"-metadata", "lyrics=[00:00.00]Remote lyric", "-c:a", "libmp3lame", path).CombinedOutput(); err != nil {
		t.Fatal(err, string(out))
	}
	var reads atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reads.Add(1)
		if r.UserAgent() == "" {
			t.Error("probe request had no user agent")
		}
		http.ServeFile(w, r, path)
	}))
	defer server.Close()
	track, err := probeMetadata(context.Background(), server.URL+"/signed-path?opaque=1", "original.mp3", probeUserAgent)
	if err != nil || track.Title != "Remote Title" || track.Artist != "Remote Artist" || track.Album != "Remote Album" ||
		track.Format != "mp3" || track.Duration <= 0 || !strings.Contains(track.TagLyrics, "Remote lyric") || reads.Load() == 0 {
		t.Fatalf("remote tags: %+v %v", track, err)
	}
}

func TestCloudURLAndConfigurationValidation(t *testing.T) {
	for _, value := range []string{"https://fscdn.115.com/a", "http://fscdn.115.com/a", "https://115.com:443/a", "http://cdn.115cdn.com:80/a", "https://CDN.ANXIA.COM/a?t=123&f=1",
		"https://cdnfhnfile.115cdn.net/a?t=123&f=1", "https://115cdn.net/a", "https://CDNFHNFILE.115CDN.NET:443/a", "http://cdnfhnfile.115cdn.net:80/a"} {
		if !validCloudURL(value) {
			t.Fatal("trusted CDN URL rejected", value)
		}
	}
	for _, value := range []string{"file:///etc/passwd", "https://115.com.attacker.test/a", "https://user@115.com/a", "https://127.0.0.1/a", "https://115.com:80/a", "http://115.com:443/a", "https://115.com:8080/a", "https://115.com:/a", "https://115.com/a#fragment", "//115.com/a", "https://115.com%2F.attacker.test/a",
		"https://115cdn.net.attacker.test/a", "https://evil115cdn.net/a", "https://115cdn.net@attacker.test/a", "https://cdnfhnfile.115cdn.net:8080/a"} {
		if validCloudURL(value) {
			t.Fatal("untrusted URL accepted", value)
		}
	}
	s := testServer(t)
	token := loginToken(t, s)
	for _, settings := range []CloudSettings{
		{RootID: "../escape", BaseURL: "https://music.example.com"},
		{RootID: "0", BaseURL: "https://secret@music.example.com"},
		{RootID: "0", BaseURL: "file:///tmp"},
		{RootID: "0", BaseURL: "https://music.example.com?token=secret"},
	} {
		body, _ := json.Marshal(settings)
		if w := request(s.Handler(), "PUT", "/api/v1/cloud115", string(body), token); w.Code != 400 {
			t.Fatal("invalid settings accepted", settings)
		}
	}
	sum := sha256.Sum256([]byte("42\x007"))
	if cloudTrackID("42", "7") == hex.EncodeToString(sum[:]) || cloudTrackID("42", "7") == cloudTrackID("43", "7") {
		t.Fatal("cloud IDs are not namespaced")
	}
}
