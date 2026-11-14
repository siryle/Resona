package resona

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestManagedStagedCopyPublicationAndRollback(t *testing.T) {
	for _, action := range []string{"copy", "move", "rename"} {
		for _, failSave := range []bool{false, true} {
			name := action
			if failSave {
				name += "/failed-save"
			}
			t.Run(name, func(t *testing.T) {
				s := testServer(t)
				from := filepath.Join(s.config.LibraryDir, "source")
				to := filepath.Join(s.config.LibraryDir, "destination")
				if err := os.Mkdir(from, 0750); err != nil {
					t.Fatal(err)
				}
				original := filepath.Join(from, "song.mp3")
				if err := os.WriteFile(original, []byte("complete audio"), 0640); err != nil {
					t.Fatal(err)
				}
				if err := s.store.update(func(st *libraryState) error {
					st.Tracks["song"] = DiskTrack{Track: Track{ID: "song", Favorite: true}, File: original}
					return nil
				}); err != nil {
					t.Fatal(err)
				}
				root, err := os.OpenRoot("/")
				if err != nil {
					t.Fatal(err)
				}
				defer root.Close()
				source, _ := managedPath(from)
				dest, _ := managedPath(to)
				originalStore := s.store.path
				if failSave {
					s.store.path = filepath.Join(s.config.DataDir, "missing.sqlite")
				}
				err = s.operateFile(context.Background(), fileOperation{Action: action}, root, "//", source, root, "/", dest)
				s.store.path = originalStore
				if (err != nil) != failSave {
					t.Fatal("unexpected publication result", err)
				}
				wantPath := original
				if !failSave {
					if got := string(mustReadFile(t, filepath.Join(to, "song.mp3"))); got != "complete audio" {
						t.Fatal("published incomplete directory", got)
					}
					requireMusicPermissions(t, to)
					if action != "copy" {
						wantPath = filepath.Join(to, "song.mp3")
						if _, err := os.Stat(from); !os.IsNotExist(err) {
							t.Fatal("completed move retained its source", err)
						}
					}
				} else if _, err := os.Stat(to); !os.IsNotExist(err) {
					t.Fatal("rollback retained destination", err)
				}
				track, _ := s.store.Track("song")
				if track.Path != wantPath || !track.Favorite || string(mustReadFile(t, wantPath)) != "complete audio" {
					t.Fatal("publication or rollback damaged index", track)
				}
				if _, err := os.Stat(s.fileJournal()); !os.IsNotExist(err) {
					t.Fatal("completed operation retained recovery journal", err)
				}
				if matches, _ := filepath.Glob(filepath.Join(s.config.LibraryDir, ".resona-*")); len(matches) != 0 {
					t.Fatal("completed operation retained staged entries", matches)
				}
			})
		}
	}
}
