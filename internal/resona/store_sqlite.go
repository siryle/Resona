package resona

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"

	_ "modernc.org/sqlite"
)

const librarySchema = `
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, data BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS tracks (
 id TEXT PRIMARY KEY, library TEXT NOT NULL, added_at TEXT NOT NULL,
 favorite INTEGER NOT NULL, album_id TEXT NOT NULL, artist TEXT NOT NULL,
 album_artist TEXT NOT NULL, disc INTEGER NOT NULL, number INTEGER NOT NULL,
 title_key TEXT NOT NULL, artist_key TEXT NOT NULL, search TEXT NOT NULL,
 unavailable INTEGER NOT NULL, metadata_source TEXT NOT NULL, visible INTEGER NOT NULL,
 size INTEGER NOT NULL, duration REAL NOT NULL, data BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS tracks_added ON tracks(visible, added_at DESC, id);
CREATE INDEX IF NOT EXISTS tracks_library ON tracks(visible, library, added_at DESC, id);
CREATE INDEX IF NOT EXISTS tracks_favorite ON tracks(visible, library, favorite, added_at DESC, id);
CREATE INDEX IF NOT EXISTS tracks_album ON tracks(visible, album_id, disc, number, added_at DESC, id);
CREATE INDEX IF NOT EXISTS tracks_artist ON tracks(visible, artist);
CREATE INDEX IF NOT EXISTS tracks_album_artist ON tracks(visible, album_artist);
CREATE INDEX IF NOT EXISTS tracks_identity ON tracks(library, title_key, artist_key);
CREATE TABLE IF NOT EXISTS track_aliases (
 track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
 previous_id TEXT NOT NULL, PRIMARY KEY(track_id, previous_id)
);
CREATE INDEX IF NOT EXISTS aliases_previous ON track_aliases(previous_id);
CREATE TABLE IF NOT EXISTS lyrics (
 track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
 kind TEXT NOT NULL, data BLOB NOT NULL, PRIMARY KEY(track_id, kind)
);
CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, position INTEGER NOT NULL, data BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS job_items (
 job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
 position INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(job_id, position)
);
CREATE TABLE IF NOT EXISTS cloud_items (id TEXT PRIMARY KEY, account TEXT NOT NULL, state TEXT NOT NULL, path TEXT NOT NULL, data BLOB NOT NULL);
CREATE INDEX IF NOT EXISTS cloud_state ON cloud_items(account, state, path, id);
CREATE INDEX IF NOT EXISTS cloud_path ON cloud_items(account, path, id);
CREATE TABLE IF NOT EXISTS probe_queue (
 position INTEGER PRIMARY KEY, track_id TEXT NOT NULL UNIQUE
);
PRAGMA user_version = 1;
`

func openDatabase(dir string) (_ *Store, err error) {
	path := filepath.Join(dir, "library.sqlite")
	if info, statErr := os.Lstat(path); statErr == nil && !info.Mode().IsRegular() {
		return nil, errors.New("library database is not a regular file")
	} else if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
		return nil, statErr
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	err = f.Chmod(0600)
	info, statErr := f.Stat()
	err = errors.Join(err, statErr)
	err = errors.Join(err, f.Close())
	if err != nil {
		return nil, err
	}
	u := url.URL{Scheme: "file", Path: path}
	q := url.Values{"_pragma": {"foreign_keys(1)", "busy_timeout(5000)", "synchronous(FULL)"}}
	db, err := sql.Open("sqlite", u.String()+"?"+q.Encode())
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			db.Close()
		}
	}()
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(4)
	s := &Store{path: path, db: db, file: info, state: libraryState{Tracks: map[string]DiskTrack{}, Jobs: []Job{}}}
	var version int
	if err = db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return nil, fmt.Errorf("read library database (refusing to replace corrupt data): %w", err)
	}
	if version > 1 {
		return nil, fmt.Errorf("unsupported library database version %d", version)
	}
	var integrity string
	if err = db.QueryRow("PRAGMA quick_check").Scan(&integrity); err != nil {
		return nil, err
	}
	if integrity != "ok" {
		return nil, fmt.Errorf("library database integrity check failed: %s", integrity)
	}
	var mode string
	if err = db.QueryRow("PRAGMA journal_mode=WAL").Scan(&mode); err != nil {
		return nil, err
	}
	if mode != "wal" {
		return nil, errors.New("library database requires WAL support")
	}
	if version == 0 {
		var tables int
		if err = db.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").Scan(&tables); err != nil {
			return nil, err
		}
		if tables != 0 {
			return nil, errors.New("unrecognized library database schema")
		}
		if err = s.transaction(func(tx *sql.Tx) error {
			_, err := tx.Exec(librarySchema)
			return err
		}); err != nil {
			return nil, err
		}
	}
	var initialized int
	if err = db.QueryRow("SELECT count(*) FROM settings WHERE key='initialized'").Scan(&initialized); err != nil {
		return nil, err
	}
	legacy := filepath.Join(dir, "library.json")
	if initialized == 0 {
		var existing int
		if err = db.QueryRow(`SELECT (SELECT count(*) FROM tracks)+(SELECT count(*) FROM jobs)+
(SELECT count(*) FROM cloud_items)+(SELECT count(*) FROM settings)+(SELECT count(*) FROM lyrics)+
(SELECT count(*) FROM track_aliases)+(SELECT count(*) FROM job_items)+(SELECT count(*) FROM probe_queue)`).Scan(&existing); err != nil {
			return nil, err
		}
		if existing != 0 {
			return nil, errors.New("library initialization marker is missing; refusing to replace existing data")
		}
		data, readErr := os.ReadFile(legacy)
		if readErr == nil {
			if err = json.Unmarshal(data, &s.state); err != nil {
				return nil, fmt.Errorf("read legacy library (refusing to replace corrupt data): %w", err)
			}
		} else if !errors.Is(readErr, os.ErrNotExist) {
			return nil, readErr
		} else {
			_, backupErr := os.Lstat(legacy + ".migrated")
			if backupErr == nil {
				return nil, errors.New("library database is missing; restore the database backup or explicitly restore library.json.migrated")
			}
			if !errors.Is(backupErr, os.ErrNotExist) {
				return nil, backupErr
			}
		}
		if s.state.Tracks == nil {
			s.state.Tracks = map[string]DiskTrack{}
		}
		if err = s.persist(libraryState{}, s.state); err != nil {
			return nil, fmt.Errorf("import library: %w", err)
		}
	}
	if err = s.load(); err != nil {
		return nil, fmt.Errorf("load library database: %w", err)
	}
	// Keep a private rollback snapshot; the database becomes authoritative after import commits.
	if _, statErr := os.Stat(legacy); statErr == nil {
		if err = os.Chmod(legacy, 0600); err != nil {
			return nil, err
		}
		if _, backupErr := os.Lstat(legacy + ".migrated"); backupErr == nil {
			return nil, errors.New("legacy library and migration backup both exist; refusing to overwrite the backup")
		} else if !errors.Is(backupErr, os.ErrNotExist) {
			return nil, backupErr
		}
		if err = os.Rename(legacy, legacy+".migrated"); err != nil {
			return nil, err
		}
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return nil, statErr
	}
	return s, nil
}

func (s *Store) transaction(fn func(*sql.Tx) error) error {
	// Refuse writes if the backing file was moved/replaced, including during file-operation recovery.
	info, err := os.Stat(s.path)
	if err != nil {
		return err
	}
	if !os.SameFile(info, s.file) {
		return errors.New("library database path changed")
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func encodeRow(tx *sql.Tx, query string, value any, args ...any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	_, err = tx.Exec(query, append(args, data)...)
	return err
}

func trackKey(value string) string {
	return strings.ToLower(strings.Join(strings.Fields(value), " "))
}

func saveTrack(tx *sql.Tx, id string, old, next DiskTrack, visible bool) error {
	if next.ID == "" {
		_, err := tx.Exec("DELETE FROM tracks WHERE id=?", id)
		return err
	}
	payload := next
	payload.Track = publicTrack(next)
	payload.Lyrics, payload.EmbeddedLyrics, payload.PreviousIDs = nil, nil, nil
	t := payload.Track
	if err := encodeRow(tx, `INSERT INTO tracks VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(id) DO UPDATE SET library=excluded.library, added_at=excluded.added_at,
favorite=excluded.favorite, album_id=excluded.album_id, artist=excluded.artist,
album_artist=excluded.album_artist, disc=excluded.disc, number=excluded.number,
title_key=excluded.title_key, artist_key=excluded.artist_key, search=excluded.search,
unavailable=excluded.unavailable, metadata_source=excluded.metadata_source, visible=excluded.visible,
size=excluded.size, duration=excluded.duration, data=excluded.data`,
		payload, id, t.Library, t.AddedAt.UTC().Format("2006-01-02T15:04:05.000000000Z"),
		t.Favorite, albumID(t), t.Artist, t.AlbumArtist, t.Disc, t.Number,
		trackKey(t.Title), trackKey(t.Artist), strings.ToLower(t.Title+" "+t.Artist+" "+t.Album),
		t.Unavailable, t.MetadataSource, visible, t.Size, t.Duration); err != nil {
		return err
	}
	if !reflect.DeepEqual(old.PreviousIDs, next.PreviousIDs) {
		if _, err := tx.Exec("DELETE FROM track_aliases WHERE track_id=?", id); err != nil {
			return err
		}
		for _, previous := range next.PreviousIDs {
			if _, err := tx.Exec("INSERT OR IGNORE INTO track_aliases VALUES(?,?)", id, previous); err != nil {
				return err
			}
		}
	}
	for _, lyric := range []struct {
		kind      string
		old, next *SavedLyrics
	}{{"saved", old.Lyrics, next.Lyrics}, {"embedded", old.EmbeddedLyrics, next.EmbeddedLyrics}} {
		if reflect.DeepEqual(lyric.old, lyric.next) {
			continue
		}
		if lyric.next == nil {
			if _, err := tx.Exec("DELETE FROM lyrics WHERE track_id=? AND kind=?", id, lyric.kind); err != nil {
				return err
			}
		} else if err := encodeRow(tx, "INSERT INTO lyrics VALUES(?,?,?) ON CONFLICT(track_id,kind) DO UPDATE SET data=excluded.data",
			lyric.next, id, lyric.kind); err != nil {
			return err
		}
	}
	return nil
}

func saveJobs(tx *sql.Tx, old, next []Job) error {
	previous := make(map[string]Job, len(old))
	for _, j := range old {
		previous[j.ID] = j
	}
	for i, j := range next {
		before, exists := previous[j.ID]
		delete(previous, j.ID)
		header, oldHeader := j, before
		header.Items, oldHeader.Items = nil, nil
		if !exists || !reflect.DeepEqual(header, oldHeader) || i >= len(old) || old[i].ID != j.ID {
			if err := encodeRow(tx, "INSERT INTO jobs VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET position=excluded.position,data=excluded.data",
				header, j.ID, i); err != nil {
				return err
			}
		}
		for k, item := range j.Items {
			if k < len(before.Items) && before.Items[k] == item {
				continue
			}
			if err := encodeRow(tx, "INSERT INTO job_items VALUES(?,?,?) ON CONFLICT(job_id,position) DO UPDATE SET data=excluded.data",
				item, j.ID, k); err != nil {
				return err
			}
		}
		if len(j.Items) < len(before.Items) {
			if _, err := tx.Exec("DELETE FROM job_items WHERE job_id=? AND position>=?", j.ID, len(j.Items)); err != nil {
				return err
			}
		}
	}
	for id := range previous {
		if _, err := tx.Exec("DELETE FROM jobs WHERE id=?", id); err != nil {
			return err
		}
	}
	return nil
}

func saveQueue(tx *sql.Tx, old, next []string) error {
	if reflect.DeepEqual(old, next) {
		return nil
	}
	if len(old) > 0 && reflect.DeepEqual(old[1:], next) {
		_, err := tx.Exec("DELETE FROM probe_queue WHERE track_id=?", old[0])
		return err
	}
	if len(next) >= len(old) && reflect.DeepEqual(next[:len(old)], old) {
		var last int64
		if err := tx.QueryRow("SELECT coalesce(max(position),0) FROM probe_queue").Scan(&last); err != nil {
			return err
		}
		for i, id := range next[len(old):] {
			if _, err := tx.Exec("INSERT INTO probe_queue VALUES(?,?)", last+int64(i)+1, id); err != nil {
				return err
			}
		}
		return nil
	}
	if _, err := tx.Exec("DELETE FROM probe_queue"); err != nil {
		return err
	}
	for i, id := range next {
		if _, err := tx.Exec("INSERT INTO probe_queue VALUES(?,?)", i, id); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) persist(old, next libraryState) error {
	return s.transaction(func(tx *sql.Tx) error {
		for id, track := range next.Tracks {
			before, exists := old.Tracks[id]
			visible := track.Remote == nil || next.Cloud.Items[id].State != "skipped"
			wasVisible := before.Remote == nil || old.Cloud.Items[id].State != "skipped"
			if exists && visible == wasVisible && reflect.DeepEqual(before, track) {
				continue
			}
			if err := saveTrack(tx, id, before, track, visible); err != nil {
				return err
			}
		}
		for id := range old.Tracks {
			if _, exists := next.Tracks[id]; !exists {
				if _, err := tx.Exec("DELETE FROM tracks WHERE id=?", id); err != nil {
					return err
				}
			}
		}
		for id, item := range next.Cloud.Items {
			if before, exists := old.Cloud.Items[id]; exists && reflect.DeepEqual(before, item) {
				continue
			}
			if err := encodeRow(tx, "INSERT INTO cloud_items VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET account=excluded.account,state=excluded.state,path=excluded.path,data=excluded.data",
				item, id, item.Account, item.State, item.Path); err != nil {
				return err
			}
		}
		for id := range old.Cloud.Items {
			if _, exists := next.Cloud.Items[id]; !exists {
				if _, err := tx.Exec("DELETE FROM cloud_items WHERE id=?", id); err != nil {
					return err
				}
			}
		}
		if err := saveJobs(tx, old.Jobs, next.Jobs); err != nil {
			return err
		}
		if err := saveQueue(tx, old.Cloud.ProbeQueue, next.Cloud.ProbeQueue); err != nil {
			return err
		}
		oldCloud, nextCloud := old.Cloud, next.Cloud
		oldCloud.Items, oldCloud.ProbeQueue = nil, nil
		nextCloud.Items, nextCloud.ProbeQueue = nil, nil
		for _, setting := range []struct {
			key       string
			old, next any
		}{{"sources", old.Sources, next.Sources}, {"plugins", old.Plugins, next.Plugins},
			{"cloud", oldCloud, nextCloud}, {"scan", old.ScanSchedule, next.ScanSchedule}} {
			if reflect.DeepEqual(setting.old, setting.next) && old.Tracks != nil {
				continue
			}
			if err := encodeRow(tx, "INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET data=excluded.data", setting.next, setting.key); err != nil {
				return err
			}
		}
		if old.Tracks == nil {
			_, err := tx.Exec("INSERT INTO settings VALUES('initialized','true')")
			return err
		}
		return nil
	})
}

func (s *Store) load() error {
	s.state = libraryState{Tracks: map[string]DiskTrack{}, Jobs: []Job{}, Cloud: CloudState{Items: map[string]CloudItem{}}}
	if err := s.readRows("SELECT key,data FROM settings", func(key string, data []byte) error {
		switch key {
		case "sources":
			return json.Unmarshal(data, &s.state.Sources)
		case "plugins":
			return json.Unmarshal(data, &s.state.Plugins)
		case "cloud":
			return json.Unmarshal(data, &s.state.Cloud)
		case "scan":
			return json.Unmarshal(data, &s.state.ScanSchedule)
		}
		return nil
	}); err != nil {
		return err
	}
	s.state.Cloud.Items = map[string]CloudItem{}
	if err := s.readRows("SELECT id,data FROM tracks", func(id string, data []byte) error {
		var track DiskTrack
		if err := json.Unmarshal(data, &track); err != nil {
			return err
		}
		s.state.Tracks[id] = track
		return nil
	}); err != nil {
		return err
	}
	if err := s.readRows("SELECT track_id,previous_id FROM track_aliases ORDER BY rowid", func(id string, data []byte) error {
		track := s.state.Tracks[id]
		track.PreviousIDs = append(track.PreviousIDs, string(data))
		s.state.Tracks[id] = track
		return nil
	}); err != nil {
		return err
	}
	rows, err := s.db.Query("SELECT track_id,kind,data FROM lyrics")
	if err != nil {
		return err
	}
	for rows.Next() {
		var id, kind string
		var data []byte
		if err = rows.Scan(&id, &kind, &data); err != nil {
			break
		}
		var lyric SavedLyrics
		if err = json.Unmarshal(data, &lyric); err != nil {
			break
		}
		track := s.state.Tracks[id]
		if kind == "embedded" {
			track.EmbeddedLyrics = &lyric
		} else {
			track.Lyrics = &lyric
		}
		s.state.Tracks[id] = track
	}
	err = errors.Join(err, rows.Err(), rows.Close())
	if err != nil {
		return err
	}
	if err := s.readRows("SELECT id,data FROM jobs ORDER BY position", func(_ string, data []byte) error {
		var job Job
		if err := json.Unmarshal(data, &job); err != nil {
			return err
		}
		s.state.Jobs = append(s.state.Jobs, job)
		return nil
	}); err != nil {
		return err
	}
	jobIndex := make(map[string]int, len(s.state.Jobs))
	for i, job := range s.state.Jobs {
		jobIndex[job.ID] = i
	}
	if err := s.readRows("SELECT job_id,data FROM job_items ORDER BY position", func(id string, data []byte) error {
		var item JobItem
		if err := json.Unmarshal(data, &item); err != nil {
			return err
		}
		i, ok := jobIndex[id]
		if !ok {
			return errors.New("task detail references a missing task")
		}
		s.state.Jobs[i].Items = append(s.state.Jobs[i].Items, item)
		return nil
	}); err != nil {
		return err
	}
	if err := s.readRows("SELECT id,data FROM cloud_items", func(id string, data []byte) error {
		var item CloudItem
		if err := json.Unmarshal(data, &item); err != nil {
			return err
		}
		s.state.Cloud.Items[id] = item
		return nil
	}); err != nil {
		return err
	}
	return s.readRows("SELECT track_id,track_id FROM probe_queue ORDER BY position", func(id string, _ []byte) error {
		s.state.Cloud.ProbeQueue = append(s.state.Cloud.ProbeQueue, id)
		return nil
	})
}

func (s *Store) readRows(query string, read func(string, []byte) error) error {
	rows, err := s.db.Query(query)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var data []byte
		if err := rows.Scan(&id, &data); err != nil {
			return err
		}
		if err := read(id, data); err != nil {
			return err
		}
	}
	return rows.Err()
}

// Hot single-song writes copy and compare only that song and its remote state.
func (s *Store) updateEntry(id string, fn func(*libraryState) error) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	before := libraryState{Tracks: map[string]DiskTrack{}, Cloud: CloudState{Items: map[string]CloudItem{}}}
	if track, ok := s.state.Tracks[id]; ok {
		before.Tracks[id] = track
	}
	if item, ok := s.state.Cloud.Items[id]; ok {
		before.Cloud.Items[id] = item
	}
	next := s.state
	entries := cloneLibrary(before)
	next.Tracks, next.Cloud.Items = entries.Tracks, entries.Cloud.Items
	next.Jobs, next.Cloud.ProbeQueue = nil, nil
	if err := fn(&next); err != nil {
		return err
	}
	old := next
	old.Tracks, old.Cloud.Items = before.Tracks, before.Cloud.Items
	if err := s.persist(old, next); err != nil {
		return err
	}
	if track, ok := next.Tracks[id]; ok {
		s.state.Tracks[id] = track
	} else {
		delete(s.state.Tracks, id)
	}
	if item, ok := next.Cloud.Items[id]; ok {
		if s.state.Cloud.Items == nil {
			s.state.Cloud.Items = map[string]CloudItem{}
		}
		s.state.Cloud.Items[id] = item
	} else {
		delete(s.state.Cloud.Items, id)
	}
	return nil
}

func (s *Store) dequeueProbe(id string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	queue := s.state.Cloud.ProbeQueue
	if len(queue) == 0 || queue[0] != id {
		return nil
	}
	if err := s.transaction(func(tx *sql.Tx) error {
		_, err := tx.Exec("DELETE FROM probe_queue WHERE track_id=?", id)
		return err
	}); err != nil {
		return err
	}
	s.state.Cloud.ProbeQueue = queue[1:]
	return nil
}

func (s *Store) savePluginOffset(token string, offset int64) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	next := s.state.Plugins
	if next.Music.Token != token || next.Offset == offset {
		return nil
	}
	next.Offset = offset
	if err := s.transaction(func(tx *sql.Tx) error {
		return encodeRow(tx, "UPDATE settings SET data=? WHERE key='plugins'", next)
	}); err != nil {
		return err
	}
	s.state.Plugins = next
	return nil
}
