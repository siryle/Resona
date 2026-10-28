package resona

import (
	"bytes"
	"context"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Run explicitly for the real-backend browser smoke test in scripts/test-web.cjs.
func TestBrowserFixture(t *testing.T) {
	if os.Getenv("RESONA_BROWSER_FIXTURE") != "1" {
		t.Skip("browser fixture is opt-in")
	}
	s := testServer(t)
	audio := filepath.Join(s.config.LibraryDir, "fixture.mp3")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "120", "-c:a", "libmp3lame", audio).CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg: %s: %v", out, err)
	}
	hash, size, err := hashFile(context.Background(), audio)
	if err != nil {
		t.Fatal(err)
	}
	audioBytes, err := os.ReadFile(audio)
	if err != nil {
		t.Fatal(err)
	}
	cloudAudio := filepath.Join(t.TempDir(), "cloud.flac")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-i", audio, "-c:a", "flac", cloudAudio).CombinedOutput(); err != nil {
		t.Fatalf("cloud FLAC fixture: %s: %v", out, err)
	}
	cloudBytes := mustReadFile(t, cloudAudio)
	digest := sha1.Sum(cloudBytes)
	var downloadAgent atomic.Value
	var cdnRequests atomic.Int32
	cdn := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
			t.Error("Resona credentials forwarded to the mock CDN")
		}
		if expected, ok := downloadAgent.Load().(string); !ok || r.UserAgent() != expected {
			t.Error("UA-bound CDN link requested with a different User-Agent")
			w.WriteHeader(403)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		if cdnRequests.Add(1) == 1 {
			w.WriteHeader(403)
			return
		}
		w.Header().Set("Content-Type", "audio/flac")
		http.ServeContent(w, r, "resona-fixture.flac", time.Time{}, bytes.NewReader(cloudBytes))
	}))
	defer cdn.Close()
	cipherKey := cloudTestCipher(t)
	var qrPolls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/1.0/web/1.0/token/":
			qrPolls.Store(0)
			cloudResponse(w, map[string]any{"uid": "fixture-qr", "time": 1, "sign": "fixture-sign", "qrcode": "https://115.com/scan/dg-fixture-qr"})
		case "/get/status/":
			status := 1
			if qrPolls.Add(1) > 1 {
				status = 2
			}
			cloudResponse(w, map[string]any{"status": status})
		case "/app/1.0/alipaymini/1.0/login/qrcode/", "/app/1.0/wechatmini/1.0/login/qrcode/",
			"/app/1.0/115android/1.0/login/qrcode/", "/app/1.0/115ios/1.0/login/qrcode/",
			"/app/1.0/web/1.0/login/qrcode/", "/app/1.0/115ipad/1.0/login/qrcode/", "/app/1.0/tv/1.0/login/qrcode/":
			cloudResponse(w, map[string]any{"cookie": map[string]string{"UID": "42_A1", "CID": "private-cid", "SEID": "private-seid"}})
		case "/":
			cloudResponse(w, map[string]any{"user_id": 42, "user_name": "Fixture Account"})
		case "/user/info":
			cloudResponse(w, map[string]any{"user_id": "42", "user_name": "Fixture Account", "mark3": 1023,
				"rt_space_info": map[string]any{"all_total": map[string]any{"size": "65981693290000"},
					"all_use": map[string]any{"size": "50236675250000"}}})
		case "/files":
			jsonResponse(w, 200, map[string]any{"state": true, "cid": "0", "path": []any{map[string]any{"cid": "0"}}, "count": 1, "data": []any{
				map[string]any{"fid": "77", "cid": "0", "fn": "Cloud Song.flac", "fc": "1", "pc": "abcdefghijklmnopq", "sha1": fmt.Sprintf("%x", digest), "fs": len(cloudBytes)},
			}})
		case "/app/chrome/downurl", "/android/2.0/ufile/download":
			downloadAgent.Store(r.UserAgent())
			cloudDownloadResponse(t, w, r, cipherKey, "77", "https://cdnfhnfile.115cdn.net/resona-fixture.flac?f=1")
		default:
			w.WriteHeader(404)
		}
	}))
	defer upstream.Close()
	s.cloud.apiURL, s.cloud.webURL, s.cloud.userURL, s.cloud.qrURL = upstream.URL, upstream.URL, upstream.URL, upstream.URL
	s.cloud.probe = func(ctx context.Context, item CloudItem) (Track, error) {
		if err := os.WriteFile(strings.TrimSuffix(s.cloud.strmPath(item), ".strm")+".lrc", []byte("[00:00.00]Cloud sidecar lyric"), 0777); err != nil {
			return Track{}, err
		}
		if _, err := s.cloud.downloadURL(ctx, item.RemoteFile, probeUserAgent); err != nil {
			return Track{}, err
		}
		track, err := readMetadata(ctx, cloudAudio)
		track.Title, track.Artist, track.AlbumArtist, track.Album = "Cloud Song", "Cloud Artist", "Cloud Artist", "Cloud Album"
		return track, err
	}
	lyrics, err := makeLyrics("[00:00.00]First line\n[00:02.00]Second line", "embedded")
	if err != nil {
		t.Fatal(err)
	}
	firstAudio := filepath.Join(s.config.LibraryDir, "song.mp3")
	if err := os.WriteFile(firstAudio, audioBytes, 0640); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(strings.TrimSuffix(firstAudio, ".mp3")+".lrc", []byte("[00:00.00]First line\n[00:02.00]Second line"), 0640); err != nil {
		t.Fatal(err)
	}
	err = s.store.update(func(st *libraryState) error {
		for i := 0; i < 105; i++ {
			id := fmt.Sprintf("%064x", i+1)
			title := fmt.Sprintf("Song %03d", i+1)
			if i == 0 {
				id = hash
				title = "Song"
			}
			st.Tracks[id] = DiskTrack{Track: Track{ID: id, Title: title, Artist: "Artist", AlbumArtist: "Artist", Album: "Album", Duration: 120, Format: "mp3", SampleRate: 44100, Bitrate: 128000, Size: size, AddedAt: time.Now().Add(-time.Duration(i) * time.Minute)}, File: audio, EmbeddedLyrics: lyrics, EmbeddedChecked: true}
			if i == 0 {
				d := st.Tracks[id]
				d.File, d.EmbeddedLyrics, d.Lyrics = firstAudio, nil, lyrics
				st.Tracks[id] = d
			}
		}
		st.Jobs = []Job{
			{ID: "complete-a", State: "completed", Phase: "音乐库已更新", Processed: 12, Imported: 10, Skipped: 2, StartedAt: time.Now(), Items: []JobItem{{TrackID: hash, Filename: "song.mp3", Title: "Song", Artist: "Artist", Duration: 120, Source: "local", State: "imported"}}},
			{ID: "complete-b", State: "completed_with_errors", Phase: "扫描完成，部分文件需要检查", Processed: 20, Imported: 18, Skipped: 2, StartedAt: time.Now(), Errors: []string{"Source unavailable"}},
			{ID: "active", State: "running", Phase: "识别 · Very long song title for a single-line history record", StartedAt: time.Now()},
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"Archive", "Incoming"} {
		if err := os.Mkdir(filepath.Join(s.config.InboxDir, name), 0750); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(s.config.InboxDir, "notes.txt"), []byte("File manager fixture"), 0640); err != nil {
		t.Fatal(err)
	}
	s.logger.Debug("Fixture diagnostic")
	s.scanner.logger.Warn("Fixture scan warning")
	s.logger.With("category", "plugin").Error("Fixture plugin failure <script>alert(1)</script>")
	s.scanner.catalog = mockCatalog(t, catalogFixtures)
	avatar, err := os.ReadFile(filepath.Join("..", "..", "docs", "brand", "resona-icon.png"))
	if err != nil {
		t.Fatal(err)
	}
	if err := cacheArtwork(filepath.Join(s.config.DataDir, "artwork", "artists",
		fmt.Sprintf("%x.jpg", sha256.Sum256([]byte("Artist")))), avatar); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(s.Handler())
	defer server.Close()
	if err := s.store.update(func(st *libraryState) error {
		st.Cloud.Settings = CloudSettings{RootID: "0", BaseURL: server.URL}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	build := filepath.Join("..", "..", ".build")
	if err := os.MkdirAll(build, 0700); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(map[string]string{"url": server.URL, "cdn_address": cdn.Listener.Addr().String()})
	if err := os.WriteFile(filepath.Join(build, "browser-fixture.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	t.Log("Browser fixture ready:", server.URL)
	for deadline := time.Now().Add(15 * time.Minute); time.Now().Before(deadline); {
		if _, err := os.Stat(filepath.Join(build, "browser-done")); err == nil {
			return
		}
		time.Sleep(time.Second)
	}
	t.Fatal("browser fixture timed out")
}
