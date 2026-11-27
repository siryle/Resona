package resona

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestLocalLyricsConfinesFileReplacement(t *testing.T) {
	for _, library := range []string{"local", "cloud"} {
		t.Run(library, func(t *testing.T) {
			config := testConfig(t)
			scanner := NewScanner(config, nil)
			root := config.LibraryDir
			if library == "cloud" {
				root = filepath.Join(config.DataDir, "cloud115", "strm")
				if err := os.MkdirAll(root, 0700); err != nil {
					t.Fatal(err)
				}
			}
			stable := filepath.Join(root, "stable.lrc")
			outside := filepath.Join(t.TempDir(), "outside.txt")
			path := filepath.Join(root, "song.lrc")
			for name, text := range map[string]string{stable: "public lyrics", outside: "outside lyrics"} {
				if err := os.WriteFile(name, []byte(text), 0600); err != nil {
					t.Fatal(err)
				}
			}
			track := Track{Path: filepath.Join(root, "song.mp3"), Library: library}
			if err := os.Symlink(stable, path); err != nil {
				t.Fatal(err)
			}
			if lyric, err := scanner.localLyrics(track); err != nil || lyric.Text != "public lyrics" || !scanner.hasLocalLyrics(track) {
				t.Fatal("in-library links must remain readable", lyric, err)
			}
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(outside, path); err != nil {
				t.Fatal(err)
			}
			if lyric, err := scanner.localLyrics(track); err == nil || lyric != nil || scanner.hasLocalLyrics(track) {
				t.Fatal("outside link was accepted", lyric, err)
			}
			done := make(chan struct{})
			var workers sync.WaitGroup
			workers.Add(1)
			go func() {
				defer workers.Done()
				stage := filepath.Join(root, ".swap")
				for {
					select {
					case <-done:
						return
					default:
					}
					if os.Link(stable, stage) == nil {
						os.Rename(stage, path)
					}
					if os.Symlink(outside, stage) == nil {
						os.Rename(stage, path)
					}
				}
			}()
			defer func() { close(done); workers.Wait() }()
			for range 3000 {
				if lyric, err := scanner.localLyrics(track); err == nil && lyric.Text != "public lyrics" {
					t.Fatal("read escaped library during replacement")
				}
			}
		})
	}
}

func TestLocalLyricsBadgesRejectEmptyAndOversizedFiles(t *testing.T) {
	config := testConfig(t)
	scanner := NewScanner(config, nil)
	track := Track{Path: filepath.Join(config.LibraryDir, "song.mp3")}
	path := filepath.Join(config.LibraryDir, "song.lrc")
	for _, text := range []string{"", " \n\t", strings.Repeat("x", maxLyricsSize+1)} {
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
		if scanner.hasLocalLyrics(track) {
			t.Fatal("invalid sidecar received a lyrics badge")
		}
	}
}
