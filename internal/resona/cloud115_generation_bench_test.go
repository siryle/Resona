package resona

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"
)

func BenchmarkCloudSTRMGeneration(b *testing.B) {
	dir, err := filepath.EvalSymlinks(b.TempDir())
	if err != nil {
		b.Fatal(err)
	}
	s := &Server{ctx: context.Background(), config: Config{DataDir: dir}, store: &Store{state: libraryState{Tracks: map[string]DiskTrack{}, Cloud: CloudState{Settings: CloudSettings{BaseURL: "https://music.example.com"}}}}}
	s.cloud = newCloud115(s)
	items := make([]CloudItem, 1000)
	for i := range items {
		id := cloudTrackID("42", fmt.Sprint(i))
		items[i] = CloudItem{RemoteFile: RemoteFile{Account: "42"}, TrackID: id, Name: fmt.Sprintf("Song%d.mp3", i), Path: fmt.Sprintf("Artist/Album%d/Song%d.mp3", i/10, i)}
	}
	b.Run("initial", func(b *testing.B) {
		b.ResetTimer()
		for range b.N {
			writer := s.cloud.newSTRMWriter()
			for _, item := range items {
				if _, err := writer.write(b.Context(), item, s.cloud.strmPath(item)); err != nil {
					b.Fatal(err)
				}
			}
			writer.close()
		}
	})
	b.Run("unchanged", func(b *testing.B) {
		b.ResetTimer()
		for range b.N {
			writer := s.cloud.newSTRMWriter()
			for _, item := range items {
				if _, err := writer.write(b.Context(), item, s.cloud.strmPath(item)); err != nil {
					b.Fatal(err)
				}
			}
			writer.close()
		}
	})
}
