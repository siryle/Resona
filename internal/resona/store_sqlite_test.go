package resona

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestDatabaseMigratesLegacyLibrary(t *testing.T) {
	dir := t.TempDir()
	local := DiskTrack{
		Track: Track{ID: "local", Title: "月亮", Artist: "Artist", AlbumArtist: "Artist", Album: "Album",
			Favorite: true, MetadataLocked: true, AddedAt: time.Now().UTC()},
		File: "/music/local.mp3", PreviousIDs: []string{"original", "older"},
		Lyrics:         &SavedLyrics{Text: "online lyrics", Source: "lrclib"},
		EmbeddedLyrics: &SavedLyrics{Text: "embedded lyrics", Source: "embedded"}, EmbeddedChecked: true,
	}
	remote := RemoteFile{Account: "42", FileID: "7", SHA1: strings.Repeat("a", 40)}
	legacy := libraryState{
		Tracks: map[string]DiskTrack{"local": local, "remote": {Track: Track{ID: "remote"}, Remote: &remote}},
		Jobs:   []Job{{ID: "job", State: "running", Items: []JobItem{{TrackID: "local", State: "processing"}}}},
		Cloud: CloudState{Account: "42", Cookie: "private-cookie",
			Items:      map[string]CloudItem{"remote": {RemoteFile: remote, TrackID: "remote", State: "pending"}},
			ProbeQueue: []string{"remote"}, ProbePaused: true},
		Plugins:      PluginSettings{Music: MusicSaverSettings{Token: "private-token"}, Offset: 123},
		ScanSchedule: &ScanSchedule{Mode: "daily", Time: "04:30"},
	}
	if err := atomicJSON(filepath.Join(dir, "library.json"), legacy); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(store.state.Tracks["local"].PreviousIDs, local.PreviousIDs) ||
		!reflect.DeepEqual(store.state.Tracks["local"].Lyrics, local.Lyrics) ||
		!reflect.DeepEqual(store.state.Tracks["local"].EmbeddedLyrics, local.EmbeddedLyrics) {
		t.Fatal("migration lost lyrics or previous content identities")
	}
	if track, ok := store.Track("local"); !ok || !track.Favorite || !track.MetadataLocked ||
		track.HasEmbeddedLyrics == nil || !*track.HasEmbeddedLyrics || track.Path != local.File {
		t.Fatal("migration lost track properties", track)
	}
	if store.state.Cloud.Cookie != legacy.Cloud.Cookie || !store.state.Cloud.ProbePaused ||
		!reflect.DeepEqual(store.state.Cloud.ProbeQueue, legacy.Cloud.ProbeQueue) ||
		store.state.Plugins.Offset != 123 || store.state.ScanSchedule.Time != "04:30" {
		t.Fatal("migration lost settings or queue state")
	}
	job, ok := store.Job("job")
	if !ok || job.State != "interrupted" || job.Items[0].State != "interrupted" {
		t.Fatal("interrupted task was not recovered", job)
	}
	if track, ok, err := store.importedTrack("original"); err != nil || !ok || track.ID != "local" {
		t.Fatal("previous content hash no longer resolves", track, err)
	}
	if err := store.updateEntry("local", func(st *libraryState) error {
		track := st.Tracks["local"]
		track.Favorite = false
		st.Tracks["local"] = track
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"library.sqlite", "library.sqlite-wal", "library.sqlite-shm", "library.json.migrated"} {
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatal("private storage permissions", name, info, err)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "library.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("legacy index remains active", err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if track, _ := store.Track("local"); track.Favorite {
		t.Fatal("reopening reimported the stale legacy snapshot")
	}
	if job, _ := store.Job("job"); job.State != "interrupted" {
		t.Fatal("recovered task state was not committed")
	}
}

func TestDatabaseRefusesCorruptionAndUnknownVersions(t *testing.T) {
	t.Run("legacy import can retry after repair", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "library.json")
		if err := os.WriteFile(path, []byte("{broken"), 0600); err != nil {
			t.Fatal(err)
		}
		if store, err := OpenStore(dir); err == nil {
			store.Close()
			t.Fatal("corrupt legacy index was silently replaced")
		}
		if err := atomicJSON(path, libraryState{Tracks: map[string]DiskTrack{"saved": {Track: Track{ID: "saved"}}}}); err != nil {
			t.Fatal(err)
		}
		store, err := OpenStore(dir)
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		if _, ok := store.Track("saved"); !ok {
			t.Fatal("failed import was incorrectly marked complete")
		}
	})
	t.Run("corrupt database never falls back to legacy", func(t *testing.T) {
		dir := t.TempDir()
		os.WriteFile(filepath.Join(dir, "library.sqlite"), []byte("broken database"), 0600)
		atomicJSON(filepath.Join(dir, "library.json"), libraryState{})
		if store, err := OpenStore(dir); err == nil {
			store.Close()
			t.Fatal("corrupt database was replaced with a stale JSON snapshot")
		}
	})
	t.Run("future schema", func(t *testing.T) {
		dir := t.TempDir()
		store, err := OpenStore(dir)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := store.db.Exec("PRAGMA user_version=2"); err != nil {
			t.Fatal(err)
		}
		store.Close()
		if store, err := OpenStore(dir); err == nil {
			store.Close()
			t.Fatal("future database schema was overwritten")
		}
	})
}

func TestDatabaseSmallWritesAndRollback(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.update(func(st *libraryState) error {
		for _, id := range []string{"first", "second"} {
			st.Tracks[id] = DiskTrack{Track: Track{ID: id, Title: id},
				Lyrics: &SavedLyrics{Text: strings.Repeat("lyrics ", 10000), Source: "saved"}}
		}
		st.Jobs = []Job{{ID: "history", State: "completed", Items: []JobItem{{Filename: "first"}, {Filename: "second"}}}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	// Triggers observe actual rows written, including unintended rewrites of unchanged data.
	for _, statement := range []string{
		"CREATE TABLE audit(kind TEXT)",
		"CREATE TRIGGER audit_track AFTER UPDATE ON tracks BEGIN INSERT INTO audit VALUES('track'); END",
		"CREATE TRIGGER audit_lyrics AFTER UPDATE ON lyrics BEGIN INSERT INTO audit VALUES('lyrics'); END",
		"CREATE TRIGGER audit_job AFTER UPDATE ON job_items BEGIN INSERT INTO audit VALUES('item'); END",
	} {
		if _, err := store.db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.updateEntry("first", func(st *libraryState) error {
		track := st.Tracks["first"]
		track.Favorite = true
		st.Tracks["first"] = track
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	var writes, lyricsBytes, trackBytes int
	if err := store.db.QueryRow("SELECT count(*) FROM audit").Scan(&writes); err != nil || writes != 1 {
		t.Fatal("favorite rewrote unrelated rows", writes, err)
	}
	if err := store.db.QueryRow("SELECT length(data) FROM tracks WHERE id='first'").Scan(&trackBytes); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow("SELECT length(data) FROM lyrics WHERE track_id='first'").Scan(&lyricsBytes); err != nil || trackBytes >= lyricsBytes {
		t.Fatal("lyrics are still loaded with list metadata", trackBytes, lyricsBytes, err)
	}
	job, _ := store.Job("history")
	job.Items[1].Message = "updated"
	if err := store.putJob(job); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow("SELECT count(*) FROM audit WHERE kind='item'").Scan(&writes); err != nil || writes != 1 {
		t.Fatal("task progress rewrote unchanged file details", writes, err)
	}
	if _, err := store.db.Exec("CREATE TRIGGER reject_track BEFORE UPDATE ON tracks BEGIN SELECT RAISE(ABORT,'disk failure'); END"); err != nil {
		t.Fatal(err)
	}
	if err := store.updateEntry("first", func(st *libraryState) error {
		track := st.Tracks["first"]
		track.Favorite = false
		st.Tracks["first"] = track
		return nil
	}); err == nil {
		t.Fatal("failed transaction was accepted")
	}
	if track, _ := store.Track("first"); !track.Favorite {
		t.Fatal("failed transaction changed memory")
	}
	var favorite bool
	if err := store.db.QueryRow("SELECT favorite FROM tracks WHERE id='first'").Scan(&favorite); err != nil || !favorite {
		t.Fatal("failed transaction changed persisted data", err)
	}
}

func TestDatabaseQueriesPreserveLibrarySemantics(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.update(func(st *libraryState) error {
		st.Cloud.Items = map[string]CloudItem{"hidden": {State: "skipped"}}
		for i := range 120 {
			id := fmt.Sprintf("%03d", i)
			st.Tracks[id] = DiskTrack{Track: Track{ID: id, Title: "月亮_" + id, Artist: "歌手", AlbumArtist: "专辑歌手",
				Album: "Album", Favorite: i%2 == 0, Number: 120 - i, Duration: 5, Size: 100,
				AddedAt: time.Date(2026, 1, 1, 0, 0, 0, i, time.UTC)}}
		}
		remote := &RemoteFile{Account: "42", FileID: "1"}
		st.Tracks["cloud"] = DiskTrack{Track: Track{ID: "cloud", Title: "Remote", Album: "Album", AlbumArtist: "专辑歌手"}, Remote: remote}
		st.Tracks["hidden"] = DiskTrack{Track: Track{ID: "hidden", Title: "Hidden"}, Remote: remote}
		track := st.Tracks["000"]
		track.Artwork = "/cover"
		st.Tracks["000"] = track
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for _, scenario := range []struct {
		query string
		total int
		first string
	}{
		{"library=local&limit=2&offset=5", 120, "114"},
		{"library=local&favorite=true", 60, "118"},
		{"search=月", 120, "119"},
		{"search=_", 120, "119"},
		{"search=%25", 0, ""},
		{"artist=专辑歌手&library=local", 120, "119"},
		{"library=cloud", 1, "cloud"},
	} {
		t.Run(scenario.query, func(t *testing.T) {
			query, _ := url.ParseQuery(scenario.query)
			tracks, total, _, _, err := store.queryTracks(t.Context(), query)
			if err != nil || total != scenario.total {
				t.Fatal("query result", total, err)
			}
			if scenario.first != "" && (len(tracks) == 0 || tracks[0].ID != scenario.first) {
				t.Fatal("ordering or pagination changed", tracks)
			}
		})
	}
	query := url.Values{"library": {"local"}}
	albums, err := store.queryAlbums(t.Context(), query)
	if err != nil || len(albums) != 1 || albums[0].Artwork != "/cover" || albums[0].Tracks != 120 || albums[0].Duration != 600 {
		t.Fatal("album grouping or artwork fallback changed", albums, err)
	}
	tracks, _, _, _, err := store.queryTracks(t.Context(), url.Values{"album": {albums[0].ID}})
	if err != nil || tracks[0].ID != "119" || tracks[len(tracks)-1].ID != "020" {
		t.Fatal("album track ordering changed", err)
	}
	artists, err := store.queryArtists(t.Context(), query)
	if err != nil || len(artists) != 1 || artists[0].Tracks != 120 {
		t.Fatal("artist grouping changed", artists, err)
	}
	var plan string
	rows, err := store.db.Query("EXPLAIN QUERY PLAN SELECT data FROM tracks WHERE visible=1 AND library='local' ORDER BY added_at DESC,id LIMIT 100")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var id, parent, unused int
		var detail string
		if err := rows.Scan(&id, &parent, &unused, &detail); err != nil {
			t.Fatal(err)
		}
		plan += detail
	}
	if !strings.Contains(plan, "tracks_library") || strings.Contains(plan, "TEMP B-TREE") {
		t.Fatal("default page performs an unindexed sort", plan)
	}
}

func TestDatabaseReadersDuringWrites(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.update(func(st *libraryState) error {
		st.Tracks["song"] = DiskTrack{Track: Track{ID: "song"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	failures := make(chan error, 3)
	for worker := range 3 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range 30 {
				if worker == 0 {
					if err := store.updateEntry("song", func(st *libraryState) error {
						track := st.Tracks["song"]
						track.Favorite = i%2 == 0
						st.Tracks["song"] = track
						return nil
					}); err != nil {
						failures <- err
						return
					}
				} else if tracks, total, _, _, err := store.queryTracks(t.Context(), url.Values{}); err != nil {
					failures <- err
					return
				} else if total != 1 || len(tracks) != 1 {
					failures <- fmt.Errorf("inconsistent page: total=%d items=%d", total, len(tracks))
					return
				}
			}
		}()
	}
	wg.Wait()
	close(failures)
	for err := range failures {
		t.Error(err)
	}
}

func TestDatabaseDeletesAndQueueOrder(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.update(func(st *libraryState) error {
		st.Cloud.Account, st.Cloud.Cookie = "42", "private"
		st.Cloud.Items = map[string]CloudItem{}
		for _, id := range []string{"a", "b", "c"} {
			remote := RemoteFile{Account: "42", FileID: id}
			st.Tracks[id] = DiskTrack{Track: Track{ID: id}, Remote: &remote,
				PreviousIDs: []string{"old-" + id}, Lyrics: &SavedLyrics{Text: "text"}}
			st.Cloud.Items[id] = CloudItem{RemoteFile: remote, TrackID: id, State: "pending", Path: id}
		}
		st.Cloud.ProbeQueue = []string{"b", "a", "c"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.dequeueProbe("b"); err != nil {
		t.Fatal(err)
	}
	if err := store.updateCloud(func(st *libraryState) error {
		st.Cloud.ProbeQueue = append(st.Cloud.ProbeQueue, "d")
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.updateCloud(func(st *libraryState) error {
		removeCloudTracks(st, map[string]bool{"c": true})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"tracks", "track_aliases", "lyrics"} {
		key := "track_id"
		if table == "tracks" {
			key = "id"
		}
		var count int
		if err := store.db.QueryRow("SELECT count(*) FROM " + table + " WHERE " + key + "='c'").Scan(&count); err != nil || count != 0 {
			t.Fatal("deleted song left associated records", table, count, err)
		}
	}
	items, counts, total, _, _, err := store.queryCloudItems(t.Context(), "42", url.Values{"limit": {"1"}})
	if err != nil || total != 2 || counts["pending"] != 2 || len(items) != 1 || items[0].TrackID != "a" || !items[0].Queued {
		t.Fatal("cloud pagination or queue association changed", items, counts, total, err)
	}
	store.Close()
	store, err = OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if !reflect.DeepEqual(store.state.Cloud.ProbeQueue, []string{"a", "d"}) {
		t.Fatal("queue reordering after dequeue, append and removal", store.state.Cloud.ProbeQueue)
	}
}

func BenchmarkLibraryStorage(b *testing.B) {
	for _, count := range []int{1000, 10000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			store, err := OpenStore(b.TempDir())
			if err != nil {
				b.Fatal(err)
			}
			defer store.Close()
			if err := store.update(func(st *libraryState) error {
				for i := range count {
					id := fmt.Sprint(i)
					st.Tracks[id] = DiskTrack{Track: Track{ID: id, Title: "Song " + id, Artist: "Artist", Album: "Album"},
						Lyrics: &SavedLyrics{Text: strings.Repeat("lyrics ", 100), Source: "saved"}}
				}
				return nil
			}); err != nil {
				b.Fatal(err)
			}
			b.Run("JSONFavorite", func(b *testing.B) {
				path := filepath.Join(b.TempDir(), "library.json")
				for i := 0; i < b.N; i++ {
					next := cloneLibrary(store.state)
					track := next.Tracks["0"]
					track.Favorite = i%2 == 0
					next.Tracks["0"] = track
					if err := atomicJSON(path, next); err != nil {
						b.Fatal(err)
					}
				}
			})
			b.Run("SQLiteFavorite", func(b *testing.B) {
				for i := 0; i < b.N; i++ {
					if err := store.updateEntry("0", func(st *libraryState) error {
						track := st.Tracks["0"]
						track.Favorite = i%2 == 0
						st.Tracks["0"] = track
						return nil
					}); err != nil {
						b.Fatal(err)
					}
				}
			})
			b.Run("SQLitePage", func(b *testing.B) {
				for i := 0; i < b.N; i++ {
					if _, _, _, _, err := store.queryTracks(b.Context(), url.Values{"library": {"local"}}); err != nil {
						b.Fatal(err)
					}
				}
			})
			b.Run("JSONPage", func(b *testing.B) {
				for i := 0; i < b.N; i++ {
					tracks := store.Tracks()
					if len(tracks[:min(100, len(tracks))]) != 100 {
						b.Fatal("missing page")
					}
				}
			})
		})
	}
}
