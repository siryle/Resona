package resona

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLRCLyricsBadgesReflectReadableSidecarsOnly(t *testing.T) {
	for _, library := range []string{"local", "cloud"} {
		t.Run(library, func(t *testing.T) {
			s := testServer(t)
			root, ext := s.config.LibraryDir, ".mp3"
			if library == "cloud" {
				root, ext = filepath.Join(s.config.DataDir, "cloud115", "strm"), ".strm"
			}
			if err := os.MkdirAll(root, 0750); err != nil {
				t.Fatal(err)
			}
			if err := s.store.update(func(st *libraryState) error {
				d := DiskTrack{Track: Track{ID: "song", Title: "Song"}, File: filepath.Join(root, "song"+ext),
					EmbeddedChecked: true, EmbeddedLyrics: &SavedLyrics{Text: "embedded", Source: "embedded"},
					Lyrics: &SavedLyrics{Text: "cached", Source: "qq"}}
				if library == "cloud" {
					d.Remote = &RemoteFile{Account: "42", FileID: "7"}
				}
				st.Tracks["song"] = d
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			token := loginToken(t, s)
			check := func(want bool) {
				t.Helper()
				var detail Track
				w := request(s.Handler(), "GET", "/api/v1/tracks/song", "", token)
				if err := json.Unmarshal(w.Body.Bytes(), &detail); err != nil || detail.HasLRCLyrics != want {
					t.Fatal("incorrect detail LRC status", want, w.Body.String(), err)
				}
				var list struct{ Items []Track }
				w = request(s.Handler(), "GET", "/api/v1/tracks?library="+library, "", token)
				if err := json.Unmarshal(w.Body.Bytes(), &list); err != nil || len(list.Items) != 1 || list.Items[0].HasLRCLyrics != want {
					t.Fatal("incorrect list LRC status", want, w.Body.String(), err)
				}
			}
			path := filepath.Join(root, "song.lrc")
			check(false)
			for _, text := range []string{" ", "[00:01.00]Line", strings.Repeat("x", maxLyricsSize+1)} {
				if err := os.WriteFile(path, []byte(text), 0600); err != nil {
					t.Fatal(err)
				}
				check(strings.HasPrefix(text, "["))
			}
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			check(false)
			outside := filepath.Join(t.TempDir(), "outside.lrc")
			if err := os.WriteFile(outside, []byte("[00:01]Outside"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(outside, path); err != nil {
				t.Fatal(err)
			}
			check(false)
		})
	}
}
