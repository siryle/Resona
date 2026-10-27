package resona

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCloudLyricsRestrictionAfterDeletionPreservesRegeneratedLibrary(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	text := []byte("[00:00.00]Sidecar\n")
	sum := sha1.Sum(text)
	ids := []string{}
	for _, fileID := range []string{"7", "8", "9"} {
		id, _ := seedCloudSTRM(t, s, fileID)
		ids = append(ids, id)
		if err := s.store.update(func(st *libraryState) error {
			item := st.Cloud.Items[id]
			item.LRC = &RemoteFile{Account: "42", FileID: "10", PickCode: "abcdefghijklmnopq",
				SHA1: hex.EncodeToString(sum[:]), Size: int64(len(text))}
			st.Cloud.Items[id] = item
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.RemoveAll(filepath.Join(s.config.DataDir, "cloud115", "strm")); err != nil {
		t.Fatal(err)
	}
	calls := 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("Retry-After", "1")
		w.WriteHeader(405)
	}))
	defer api.Close()
	s.cloud.apiURL = api.URL
	s.cloud.busy = true
	if err := s.cloud.generateSTRMs(t.Context()); err != nil {
		t.Fatal(err)
	}
	if err := s.cloud.syncLyrics(t.Context()); err != nil {
		t.Fatal("optional lyrics failure was reported as STRM generation failure", err)
	}
	if calls != 4 || !strings.Contains(s.cloud.message, "歌词同步已暂停") || !strings.Contains(s.cloud.message, "剩余 3") {
		t.Fatal("restricted endpoint was hammered for every lyric or status was incorrect", calls, s.cloud.message)
	}
	for _, id := range ids {
		track, ok := s.store.Track(id)
		if !ok {
			t.Fatal("lyric rejection removed regenerated library entry")
		}
		if _, err := os.Stat(track.Path); err != nil {
			t.Fatal("lyric rejection lost regenerated STRM", err)
		}
	}
	// A later generation can fill missing lyrics without rewriting good STRMs.
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "" || r.Header.Get("Authorization") != "" {
			t.Error("lyric CDN received credentials")
		}
		w.Write(text)
	}))
	defer cdn.Close()
	s.cloud.links["42\x00abcdefghijklmnopq\x00"+probeUserAgent] = cloudLink{URL: cdn.URL, Expires: time.Now().Add(time.Hour)}
	if err := s.cloud.syncLyrics(t.Context()); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		track, _ := s.store.Track(id)
		if data := mustReadFile(t, strings.TrimSuffix(track.Path, ".strm")+".lrc"); string(data) != string(text) {
			t.Fatal("deferred lyric was not recoverable")
		}
	}
}

func TestCloudLyricsSyncIsOptionalIncrementalAndPlayableBeforeProbe(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	text := []byte("[00:00.00]Cloud sidecar lyric\n[00:02.00]Second line\n")
	sum := sha1.Sum(text)
	lyric := treeFile("2", "0", "Artist - Song.lrc")
	lyric["sha"], lyric["s"] = hex.EncodeToString(sum[:]), len(text)
	audio := treeFile("1", "0", "Artist - Song.mp3")
	reads := 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/lyric" {
			reads++
			if r.Header.Get("Cookie") != "" || r.Header.Get("Authorization") != "" {
				t.Error("credentials forwarded to lyric CDN")
			}
			w.Write(text)
			return
		}
		jsonResponse(w, 200, map[string]any{"state": true, "cid": "0", "path": []any{map[string]string{"cid": "0"}},
			"count": 2, "data": []any{audio, lyric}})
	}))
	defer api.Close()
	s.cloud.webURL = api.URL
	s.cloud.links["42\x00abcdefghijklmnopq\x00"+probeUserAgent] = cloudLink{URL: api.URL + "/lyric", Expires: time.Now().Add(time.Hour)}
	token := loginToken(t, s)
	run := func(enabled bool) {
		t.Helper()
		body := `{"download_lyrics":false}`
		if enabled {
			body = `{"download_lyrics":true}`
		}
		if w := request(s.Handler(), "POST", "/api/v1/cloud115/sync", body, token); w.Code != 202 {
			t.Fatal(w.Code, w.Body.String())
		}
		s.cloud.wg.Wait()
	}
	run(false)
	id := cloudTrackID("42", "1")
	track, ok := s.store.Track(id)
	if !ok || reads != 0 {
		t.Fatal("disabled lyric option performed a download")
	}
	run(true)
	track, _ = s.store.Track(id)
	path := strings.TrimSuffix(track.Path, ".strm") + ".lrc"
	if data := mustReadFile(t, path); string(data) != string(text) || reads != 1 {
		t.Fatal("lyric not saved alongside STRM", reads)
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0777 {
		t.Fatal("lyric permissions", err)
	}
	w := request(s.Handler(), "GET", "/api/v1/tracks/"+id+"/lyrics", "", token)
	if w.Code != 200 || w.Header().Get("X-Lyrics-Source") != "local" || !strings.Contains(w.Body.String(), "Cloud sidecar lyric") {
		t.Fatal("unprobed song cannot load sidecar lyrics", w.Code, w.Body.String())
	}
	list := request(s.Handler(), "GET", "/api/v1/tracks?library=cloud", "", token)
	if !strings.Contains(list.Body.String(), `"has_lrc_lyrics":true`) {
		t.Fatal("cloud LRC badge missing", list.Body.String())
	}
	s.cloud.probe = func(context.Context, CloudItem) (Track, error) {
		return Track{Title: "Song", Artist: "Artist", AlbumArtist: "Artist", Album: "Album", Duration: 12}, nil
	}
	if err := s.cloud.start("probe", id); err != nil {
		t.Fatal(err)
	}
	s.cloud.wg.Wait()
	track, _ = s.store.Track(id)
	path = strings.TrimSuffix(track.Path, ".strm") + ".lrc"
	if string(mustReadFile(t, path)) != string(text) || track.HasEmbeddedLyrics == nil || *track.HasEmbeddedLyrics {
		t.Fatal("probing lost sidecar lyrics or incorrectly marked them as embedded")
	}
	run(true)
	if reads != 1 {
		t.Fatal("unchanged lyric downloaded again", reads)
	}
	run(false)
	if _, err := os.Stat(path); err != nil {
		t.Fatal("disabling downloads deleted local lyrics", err)
	}
	logs := request(s.Handler(), "GET", "/api/v1/logs?category=strm", "", token)
	if logs.Code != 200 || !strings.Contains(logs.Body.String(), "生成任务开始") || !strings.Contains(logs.Body.String(), "歌词同步完成") {
		t.Fatal("STRM lifecycle logs missing", logs.Body.String())
	}
	// Corrupt downloads cannot replace existing lyrics; failure leaves the STRM indexed.
	if err := os.WriteFile(path, []byte("local copy"), 0777); err != nil {
		t.Fatal(err)
	}
	item := s.cloud.snapshot().Items[id]
	item.LRC = &RemoteFile{Account: "42", FileID: "2", PickCode: "abcdefghijklmnopq", SHA1: strings.Repeat("f", 40), Size: int64(len(text))}
	if _, err := s.cloud.syncLyric(context.Background(), item); err == nil {
		t.Fatal("corrupt lyric accepted")
	}
	if string(mustReadFile(t, path)) != "local copy" {
		t.Fatal("failed lyric sync destroyed existing copy")
	}
	if strings.Contains(path, "..") || filepath.Ext(path) != ".lrc" {
		t.Fatal("invalid sidecar destination")
	}
}
