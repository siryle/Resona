package resona

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestCloudNetCDNRetryProbesTagsAndArtwork(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("requires ffmpeg")
	}
	s := testServer(t)
	seedCloud(t, s)
	audio := filepath.Join(t.TempDir(), "song.mp3")
	if out, err := exec.Command("ffmpeg", "-v", "error",
		"-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
		"-f", "lavfi", "-i", "color=c=blue:s=16x16",
		"-t", "1", "-map", "0:a", "-map", "1:v", "-frames:v", "1",
		"-c:a", "libmp3lame", "-c:v", "mjpeg", "-disposition:v:0", "attached_pic",
		"-metadata", "title=CDN Song", "-metadata", "artist=CDN Artist", "-metadata", "album=CDN Album",
		"-metadata", "lyrics=[00:00.00]CDN lyric", audio).CombinedOutput(); err != nil {
		t.Fatal(err, string(out))
	}
	var reads atomic.Int32
	// Route the external hostname to a local HTTP fixture for the actual ffprobe/ffmpeg subprocesses.
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reads.Add(1)
		if r.URL.Hostname() != "cdnfhnfile.115cdn.net" || r.UserAgent() != probeUserAgent ||
			r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
			t.Error("unexpected CDN request or leaked credentials")
		}
		http.ServeFile(w, r, audio)
	}))
	defer proxy.Close()
	t.Setenv("http_proxy", proxy.URL)
	t.Setenv("no_proxy", "")
	t.Setenv("NO_PROXY", "")
	link := "http://cdnfhnfile.115cdn.net/song.mp3?f=1&t=" + fmt.Sprint(time.Now().Add(time.Hour).Unix())
	key := cloudTestCipher(t)
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cloudDownloadResponse(t, w, r, key, "7", link)
	}))
	defer api.Close()
	s.cloud.apiURL = api.URL
	id := cloudTrackID("42", "7")
	item := CloudItem{RemoteFile: RemoteFile{Account: "42", FileID: "7", PickCode: "abcdefghijklmnopq",
		SHA1: strings.Repeat("a", 40)}, TrackID: id, Name: "song.mp3", Path: "song.mp3",
		State: "failed", Error: "115 返回的下载地址不受信任"}
	if err := s.cloud.writeSTRM(item); err != nil {
		t.Fatal(err)
	}
	if err := s.store.update(func(st *libraryState) error {
		st.Cloud.Items[id] = item
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.cloud.start("retry", ""); err != nil {
		t.Fatal(err)
	}
	s.cloud.wg.Wait()
	state := s.cloud.snapshot()
	track, ok := s.store.Track(id)
	if !ok || state.Items[id].State != "ready" || len(state.ProbeQueue) != 0 ||
		track.Title != "CDN Song" || track.Artist != "CDN Artist" || track.Duration <= 0 ||
		track.Artwork == "" || reads.Load() < 2 {
		t.Fatalf("retry failed to publish probed audio: track=%+v item=%+v reads=%d", track, state.Items[id], reads.Load())
	}
	if cover := string(mustReadFile(t, filepath.Join(s.config.DataDir, "artwork", id+".jpg"))); !strings.HasPrefix(cover, "\xff\xd8") {
		t.Fatal("remote artwork was not cached as JPEG")
	}
	token := loginToken(t, s)
	lyrics := request(s.Handler(), "GET", "/api/v1/tracks/"+id+"/lyrics", "", token)
	if lyrics.Code != 200 || !strings.Contains(lyrics.Body.String(), "CDN lyric") {
		t.Fatal("probed lyrics unavailable", lyrics.Code, lyrics.Body.String())
	}
}
