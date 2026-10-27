package resona

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestImportCleanupRequiresVerifiedUnchangedFiles(t *testing.T) {
	for _, scenario := range []string{"success", "changed source", "changed destination", "lyrics conflict", "cancelled", "shared lyrics"} {
		t.Run(scenario, func(t *testing.T) {
			c := testConfig(t)
			s := NewScanner(c, nil)
			src := filepath.Join(c.InboxDir, "song.mp3")
			if err := os.WriteFile(src, []byte("source audio"), 0600); err != nil {
				t.Fatal(err)
			}
			original, _ := os.Stat(src)
			id, size, _ := hashFile(context.Background(), src)
			track := Track{ID: id, Size: size, Title: "Song", Artist: "Artist", Album: "Album", Format: "mp3"}
			dest, err := s.copyTrack(context.Background(), src, track)
			if err != nil {
				t.Fatal(err)
			}
			track.Path = dest
			lrc := filepath.Join(c.InboxDir, "song.lrc")
			os.WriteFile(lrc, []byte("[00:00]Lyrics"), 0600)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			switch scenario {
			case "changed source":
				os.WriteFile(src, []byte("new upload"), 0600)
			case "changed destination":
				os.WriteFile(dest, []byte("damaged copy"), 0600)
			case "lyrics conflict":
				os.WriteFile(dest[:len(dest)-4]+".lrc", []byte("other lyrics"), 0600)
			case "cancelled":
				cancel()
			case "shared lyrics":
				os.WriteFile(filepath.Join(c.InboxDir, "song.flac"), []byte("other encoding"), 0600)
			}
			err = s.removeImportedSource(ctx, c.InboxDir, src, id, original, track)
			success := scenario == "success" || scenario == "shared lyrics"
			if success != (err == nil) {
				t.Fatal("unexpected cleanup result", err)
			}
			_, statErr := os.Stat(src)
			if success != errors.Is(statErr, os.ErrNotExist) {
				t.Fatal("incorrect source retention", statErr)
			}
			_, statErr = os.Stat(lrc)
			if (scenario == "success") != errors.Is(statErr, os.ErrNotExist) {
				t.Fatal("incorrect lyrics retention", statErr)
			}
		})
	}
}

func TestFailedImportCommitKeepsSource(t *testing.T) {
	s := testServer(t)
	track := taggedAudioFixture(t, s, "mp3", "", false)
	src := filepath.Join(s.config.InboxDir, "upload.mp3")
	if err := os.Rename(track.Path, src); err != nil {
		t.Fatal(err)
	}
	indexPath := s.store.path
	s.store.path = filepath.Join(s.config.DataDir, "missing", "index.json")
	defer func() { s.store.path = indexPath }()
	s.scanner.run(context.Background(), Job{ID: "failed-commit", State: "running"})
	if id, _, err := hashFile(context.Background(), src); err != nil || id != track.ID {
		t.Fatal("failed index commit lost or changed the source", id, err)
	}
}
