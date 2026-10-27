package resona

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type Track struct {
	ID                string    `json:"id"`
	Title             string    `json:"title"`
	Artist            string    `json:"artist"`
	AlbumArtist       string    `json:"album_artist"`
	Album             string    `json:"album"`
	Year              string    `json:"year"`
	Genre             string    `json:"genre"`
	Number            int       `json:"number"`
	Disc              int       `json:"disc"`
	Duration          float64   `json:"duration"`
	Format            string    `json:"format"`
	Bitrate           int       `json:"bitrate"`
	SampleRate        int       `json:"sample_rate"`
	Size              int64     `json:"size"`
	MBID              string    `json:"mbid,omitempty"`
	ReleaseID         string    `json:"release_id,omitempty"`
	Artwork           string    `json:"artwork,omitempty"`
	Favorite          bool      `json:"favorite"`
	AddedAt           time.Time `json:"added_at"`
	Path              string    `json:"-"`
	MetadataLocked    bool      `json:"metadata_locked,omitempty"`
	MetadataSource    string    `json:"metadata_source,omitempty"`
	TagLyrics         string    `json:"-"`
	HasEmbeddedLyrics *bool     `json:"has_embedded_lyrics"`
	HasLRCLyrics      bool      `json:"has_lrc_lyrics"`
	Library           string    `json:"library"`
	HashAlgorithm     string    `json:"hash_algorithm,omitempty"`
	ContentHash       string    `json:"content_hash,omitempty"`
	Unavailable       bool      `json:"unavailable,omitempty"`
}

// DiskTrack keeps the filesystem path out of API responses.
type DiskTrack struct {
	Track
	File            string       `json:"file"`
	Lyrics          *SavedLyrics `json:"lyrics,omitempty"`
	EmbeddedLyrics  *SavedLyrics `json:"embedded_lyrics,omitempty"`
	EmbeddedChecked bool         `json:"embedded_checked,omitempty"`
	PreviousIDs     []string     `json:"previous_ids,omitempty"`
	Remote          *RemoteFile  `json:"remote,omitempty"`
}

type Job struct {
	ID        string    `json:"id"`
	Library   string    `json:"library,omitempty"`
	State     string    `json:"state"`
	Phase     string    `json:"phase"`
	Processed int       `json:"processed"`
	Imported  int       `json:"imported"`
	Skipped   int       `json:"skipped"`
	Rescrape  bool      `json:"rescrape"`
	IndexOnly bool      `json:"index_only,omitempty"`
	Errors    []string  `json:"errors"`
	StartedAt time.Time `json:"started_at"`
	EndedAt   time.Time `json:"ended_at,omitempty"`
	Items     []JobItem `json:"items,omitempty"`
}

type JobItem struct {
	Filename string  `json:"filename"`
	TrackID  string  `json:"track_id,omitempty"`
	Title    string  `json:"title,omitempty"`
	Artist   string  `json:"artist,omitempty"`
	Album    string  `json:"album,omitempty"`
	Source   string  `json:"source,omitempty"`
	State    string  `json:"state"`
	Message  string  `json:"message,omitempty"`
	Duration float64 `json:"duration"`
}

type libraryState struct {
	Tracks       map[string]DiskTrack `json:"tracks"`
	Jobs         []Job                `json:"jobs"`
	Sources      SourceSettings       `json:"sources"`
	Plugins      PluginSettings       `json:"plugins"`
	Cloud        CloudState           `json:"cloud115"`
	ScanSchedule *ScanSchedule        `json:"scan_schedule,omitempty"`
}

type Store struct {
	mu      sync.RWMutex
	writeMu sync.Mutex
	path    string
	state   libraryState
	db      *sql.DB
	file    os.FileInfo
}

func OpenStore(dir string) (*Store, error) {
	s, err := openDatabase(dir)
	if err != nil {
		return nil, err
	}
	ready := false
	defer func() {
		if !ready {
			s.Close()
		}
	}()
	for id, track := range s.state.Tracks {
		if track.Remote != nil {
			continue
		}
		backup := lyricsBackup(track.File, id)
		if info, err := os.Lstat(backup); err == nil {
			if !info.Mode().IsRegular() {
				return nil, errors.New("invalid lyrics rollback file")
			}
			if err := os.Rename(backup, track.File); err != nil {
				return nil, fmt.Errorf("restore interrupted lyrics write: %w", err)
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}
	recovered := cloneLibrary(s.state)
	changed := false
	for i := range recovered.Jobs {
		j := &recovered.Jobs[i]
		if j.State == "running" {
			changed = true
			j.Items = append([]JobItem{}, j.Items...)
			j.State, j.Phase, j.EndedAt = "interrupted", "服务重启，请重新扫描", time.Now().UTC()
			for k := range j.Items {
				if j.Items[k].State == "processing" {
					j.Items[k].State, j.Items[k].Message = "interrupted", "服务重启，请重新扫描"
				}
			}
		}
	}
	// Old Open API credentials cannot be reused as Cookies; preserve the index for re-login.
	if recovered.Cloud.Account != "" && recovered.Cloud.Cookie == "" {
		for id, track := range recovered.Tracks {
			if track.Remote != nil {
				changed = changed || !track.Unavailable
				track.Unavailable = true
				recovered.Tracks[id] = track
			}
		}
	}
	if changed {
		if err := s.persist(s.state, recovered); err != nil {
			return nil, fmt.Errorf("recover library: %w", err)
		}
		s.state = recovered
	}
	ready = true
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) update(fn func(*libraryState) error) error {
	return s.updateWithRollback(fn, nil)
}

// Cloud scans publish a new snapshot; readers can keep using the previous index while it is saved.
func (s *Store) updateCloud(fn func(*libraryState) error) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.RLock()
	next := cloneLibrary(s.state)
	s.mu.RUnlock()
	if err := fn(&next); err != nil {
		return err
	}
	if err := s.persist(s.state, next); err != nil {
		return err
	}
	s.mu.Lock()
	s.state = next
	s.mu.Unlock()
	return nil
}

// File replacement and index publication share the lock; failed persistence restores the file first.
func (s *Store) updateWithRollback(fn func(*libraryState) error, rollback func() error) (err error) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	defer func() {
		if err != nil && rollback != nil {
			err = errors.Join(err, rollback())
		}
	}()
	next := cloneLibrary(s.state)
	if err := fn(&next); err != nil {
		return err
	}
	if err := s.persist(s.state, next); err != nil {
		return err
	}
	s.state = next
	return nil
}

func cloneLibrary(st libraryState) libraryState {
	next := st
	next.Tracks = make(map[string]DiskTrack, len(st.Tracks))
	for id, track := range st.Tracks {
		next.Tracks[id] = track
	}
	next.Jobs = append([]Job{}, st.Jobs...)
	next.Cloud.ProbeQueue = append([]string{}, st.Cloud.ProbeQueue...)
	next.Cloud.Items = make(map[string]CloudItem, len(st.Cloud.Items))
	for id, item := range st.Cloud.Items {
		next.Cloud.Items[id] = item
	}
	return next
}

func atomicJSON(path string, v any) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".resona-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0600); err == nil {
		err = json.NewEncoder(f).Encode(v)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), path)
}

func (s *Store) Tracks() []Track {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Track, 0, len(s.state.Tracks))
	for _, t := range s.state.Tracks {
		if t.Remote != nil && s.state.Cloud.Items[t.ID].State == "skipped" {
			continue
		}
		out = append(out, publicTrack(t))
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].AddedAt.Equal(out[j].AddedAt) {
			return out[i].ID < out[j].ID
		}
		return out[i].AddedAt.After(out[j].AddedAt)
	})
	return out
}

func (s *Store) Track(id string) (Track, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	d, ok := s.state.Tracks[id]
	t := publicTrack(d)
	t.Path = d.File
	return t, ok
}

// Compare identified titles and performers within a source library; album and encoding do not distinguish songs.
func (s *Store) duplicateTrack(t Track) (Track, bool, error) {
	title, artist := trackKey(t.Title), trackKey(t.Artist)
	if title == "" || artist == "" || artist == "unknown artist" {
		return Track{}, false, nil
	}
	library := t.Library
	if library == "" {
		library = "local"
	}
	return s.findTrack(`SELECT data FROM tracks WHERE library=? AND title_key=? AND artist_key=?
AND id<>? AND unavailable=0 AND metadata_source<>'filename' ORDER BY id LIMIT 1`, library, title, artist, t.ID)
}

func publicTrack(d DiskTrack) Track {
	t := d.Track
	if d.Remote == nil {
		t.Library = "local"
		t.HashAlgorithm, t.ContentHash = "sha256", t.ID
	} else {
		t.Library = "cloud"
		t.HashAlgorithm, t.ContentHash = "", ""
		if validHex(d.Remote.SHA1, 40) {
			t.HashAlgorithm, t.ContentHash = "sha1", strings.ToLower(d.Remote.SHA1)
		}
		if t.Artwork != "" {
			t.Artwork = strings.Split(t.Artwork, "?")[0] + "?v=" + strings.ToLower(d.Remote.SHA1)
		}
	}
	t.HasEmbeddedLyrics = nil
	if d.EmbeddedChecked {
		present := d.EmbeddedLyrics != nil
		t.HasEmbeddedLyrics = &present
	}
	return t
}

// Retagging changes the content hash; remember original imports so scans do not duplicate them.
func (s *Store) importedTrack(id string) (Track, bool, error) {
	if t, ok := s.Track(id); ok {
		return t, true, nil
	}
	return s.findTrack(`SELECT tracks.data FROM track_aliases JOIN tracks ON tracks.id=track_aliases.track_id
WHERE previous_id=? ORDER BY tracks.id LIMIT 1`, id)
}

func (s *Store) Jobs(details ...bool) []Job {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := append([]Job{}, s.state.Jobs...)
	for i := range out {
		out[i].Errors = append([]string{}, out[i].Errors...)
		if len(details) == 0 || details[0] {
			out[i].Items = append([]JobItem{}, out[i].Items...)
		} else {
			out[i].Items = nil
		}
	}
	return out
}

func (s *Store) Job(id string) (Job, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, job := range s.state.Jobs {
		if job.ID == id {
			job.Errors = append([]string{}, job.Errors...)
			job.Items = append([]JobItem{}, job.Items...)
			for i := range job.Items {
				if track, ok := s.state.Tracks[job.Items[i].TrackID]; ok && job.Items[i].Duration <= 0 {
					job.Items[i].Duration = track.Duration
				}
			}
			return job, true
		}
	}
	return Job{}, false
}

var errJobRunning = errors.New("正在运行的任务不能删除，请等待任务结束")

func (s *Store) deleteJob(id string) error {
	return s.update(func(st *libraryState) error {
		for i, j := range st.Jobs {
			if j.ID != id {
				continue
			}
			if j.State == "running" {
				return errJobRunning
			}
			st.Jobs = append(st.Jobs[:i], st.Jobs[i+1:]...)
			return nil
		}
		return os.ErrNotExist
	})
}

func (s *Store) deleteJobs(ids []string, all bool) (int, int, error) {
	deleted, running := 0, 0
	err := s.update(func(st *libraryState) error {
		selected := make(map[string]bool, len(ids))
		for _, id := range ids {
			selected[id] = true
		}
		kept := make([]Job, 0, len(st.Jobs))
		for _, job := range st.Jobs {
			if !all && !selected[job.ID] {
				kept = append(kept, job)
				continue
			}
			delete(selected, job.ID)
			if job.State == "running" {
				if !all {
					return errJobRunning
				}
				running++
				kept = append(kept, job)
			} else {
				deleted++
			}
		}
		if len(selected) != 0 {
			return os.ErrNotExist
		}
		st.Jobs = kept
		return nil
	})
	return deleted, running, err
}

func (s *Store) putJob(j Job) error {
	j.Items = append([]JobItem{}, j.Items...)
	j.Errors = append([]string{}, j.Errors...)
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	next := append([]Job{}, s.state.Jobs...)
	found := false
	for i := range next {
		if next[i].ID == j.ID {
			next[i], found = j, true
			break
		}
	}
	if !found {
		next = append([]Job{j}, next...)
		if len(next) > 30 {
			next = next[:30]
		}
	}
	err := s.transaction(func(tx *sql.Tx) error {
		return saveJobs(tx, s.state.Jobs, next)
	})
	if err == nil {
		s.state.Jobs = next
	}
	return err
}
