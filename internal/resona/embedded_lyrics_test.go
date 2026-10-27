package resona

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestEmbeddedLyricsRealFormatsAndOldIndexes(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("integration requires ffmpeg")
	}
	if _, err := exec.LookPath("ffprobe"); err != nil {
		t.Skip("integration requires ffprobe")
	}
	for _, format := range []string{"mp3", "flac", "m4a"} {
		for _, text := range []string{"[00:00.10]Embedded line\n[00:00.20]Second line", "Plain embedded line\nSecond line"} {
			t.Run(format+"/"+text[:5], func(t *testing.T) {
				s := testServer(t)
				src := filepath.Join(s.config.LibraryDir, "old."+format)
				cmd := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3",
					"-metadata", "title=Song", "-metadata", "artist=Artist", "-metadata", "lyrics="+text, src)
				if out, err := cmd.CombinedOutput(); err != nil {
					t.Fatal(err, string(out))
				}
				metadata, err := readMetadata(context.Background(), src)
				if err != nil || metadata.TagLyrics != text {
					t.Fatal("tag lyrics not recognized", metadata.TagLyrics, err)
				}
				id, _, _ := hashFile(context.Background(), src)
				metadata.ID, metadata.Path = id, src
				if err := s.store.update(func(st *libraryState) error {
					st.Tracks[id] = DiskTrack{Track: metadata, File: src}
					return nil
				}); err != nil {
					t.Fatal(err)
				}
				before, _ := os.ReadFile(src)
				lyric, err := s.scanner.readLyrics(context.Background(), metadata)
				if err != nil || lyric.Text != text || lyric.Source != "embedded" || lyric.Synced != strings.HasPrefix(text, "[") {
					t.Fatal("old index lazy read failed", lyric, err)
				}
				reopened, err := OpenStore(s.config.DataDir)
				if err != nil || !reopened.state.Tracks[id].EmbeddedChecked || reopened.state.Tracks[id].EmbeddedLyrics == nil {
					t.Fatal("embedded cache was not persisted", err)
				}
				token := loginToken(t, s)
				path := "/api/v1/tracks/" + id + "/lyrics"
				w := request(s.Handler(), "GET", path, "", token)
				if w.Code != 200 || w.Body.String() != text || w.Header().Get("X-Lyrics-Source") != "embedded" {
					t.Fatal("embedded API response incorrect", w.Code, w.Body.String())
				}
				if w := request(s.Handler(), "POST", path+"/scrape", `{}`, token); w.Code != 409 {
					t.Fatal("implicit embedded replacement accepted", w.Code)
				}
				sidecar := strings.TrimSuffix(src, filepath.Ext(src)) + ".lrc"
				if err := os.WriteFile(sidecar, []byte("[00:00.10]Sidecar"), 0600); err != nil {
					t.Fatal(err)
				}
				lyric, err = s.scanner.readLyrics(context.Background(), metadata)
				if err != nil || lyric.Source != "local" {
					t.Fatal("sidecar priority lost", lyric, err)
				}
				if err := s.store.update(func(st *libraryState) error {
					d := st.Tracks[id]
					d.Lyrics = &SavedLyrics{Text: "Chosen online", Source: "qq"}
					st.Tracks[id] = d
					return nil
				}); err != nil {
					t.Fatal(err)
				}
				lyric, err = s.scanner.readLyrics(context.Background(), metadata)
				if err != nil || lyric.Text != "Chosen online" {
					t.Fatal("explicit online priority lost", lyric, err)
				}
				after, _ := os.ReadFile(src)
				if !bytes.Equal(before, after) {
					t.Fatal("reading lyrics modified audio")
				}
			})
		}
	}
}

func TestEmbeddedTagAliasesAndValidation(t *testing.T) {
	for _, key := range []string{"lyrics", "lyrics-eng", "lyrics:eng", "unsyncedlyrics", "unsyncedlyrics-eng", "uslt", "synced lyrics"} {
		if text := taggedLyrics(map[string]string{key: "\ufeff[00:01]Line"}); text != "[00:01]Line" {
			t.Fatal("alias not recognized", key, text)
		}
	}
	for _, text := range []string{"", " ", "bad\x00text", string([]byte{0xff}), strings.Repeat("a", maxLyricsSize+1)} {
		if _, err := makeLyrics(text, "embedded"); err == nil {
			t.Fatal("invalid lyrics accepted")
		}
	}
	if _, err := makeLyrics("", "embedded"); !errors.Is(err, errNoLyrics) {
		t.Fatal(err)
	}
}

func TestRescrapePreservesSidecarWhenOnlyExtensionCaseChanges(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("integration requires ffmpeg")
	}
	s := testServer(t)
	path := filepath.Join(s.config.LibraryDir, "Song-Artist.MP3")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=duration=0.3",
		"-metadata", "title=Song", "-metadata", "artist=Artist", path).CombinedOutput(); err != nil {
		t.Fatal(err, string(out))
	}
	sidecar := filepath.Join(s.config.LibraryDir, "Song-Artist.lrc")
	if err := os.WriteFile(sidecar, []byte("[00:00.10]Line"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.scanner.Start(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	s.scanner.Wait()
	tracks := s.store.Tracks()
	if len(tracks) != 1 {
		t.Fatal("rename lost track", s.store.Jobs())
	}
	track, _ := s.store.Track(tracks[0].ID)
	if _, err := os.Stat(track.Path); err != nil {
		t.Fatal("rename removed the indexed file", err)
	}
	sidecar = strings.TrimSuffix(track.Path, filepath.Ext(track.Path)) + ".lrc"
	if text, err := os.ReadFile(sidecar); err != nil || string(text) != "[00:00.10]Line" {
		t.Fatal("extension case change removed sidecar", err)
	}
}

func TestRenamingKeepsSharedSidecarUntilLastFormatMoves(t *testing.T) {
	dir := t.TempDir()
	old := filepath.Join(dir, "old.mp3")
	sibling := filepath.Join(dir, "old.flac")
	sidecar := filepath.Join(dir, "old.lrc")
	dest := filepath.Join(dir, "Song-Artist.mp3")
	for _, path := range []string{sibling, sidecar} {
		if err := os.WriteFile(path, []byte("preserved"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := removeUnusedLyrics(old, dest); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(sidecar); err != nil || string(data) != "preserved" {
		t.Fatal("shared lyrics deleted", err)
	}
	if err := os.Remove(sibling); err != nil {
		t.Fatal(err)
	}
	if err := removeUnusedLyrics(sibling, strings.TrimSuffix(dest, ".mp3")+".flac"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(sidecar); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unused old sidecar was not cleaned up", err)
	}
}
