package resona

import (
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
}

// shortcut: atomic JSON rewrites suit personal libraries; migrate to an indexed database for large or busy installations.
func OpenStore(dir string) (*Store, error) {
	s := &Store{path: filepath.Join(dir, "library.json"), state: libraryState{Tracks: map[string]DiskTrack{}, Jobs: []Job{}}}
	f, err := os.Open(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if err = json.NewDecoder(f).Decode(&s.state); err != nil {
		return nil, fmt.Errorf("read library (refusing to replace corrupt data): %w", err)
	}
	if s.state.Tracks == nil {
		s.state.Tracks = map[string]DiskTrack{}
	}
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
	for i := range s.state.Jobs {
		j := &s.state.Jobs[i]
		if j.State == "running" {
			j.State, j.Phase, j.EndedAt = "interrupted", "服务重启，请重新扫描", time.Now().UTC()
			for k := range j.Items {
				if j.Items[k].State == "processing" {
					j.Items[k].State, j.Items[k].Message = "interrupted", "服务重启，请重新扫描"
				}
			}
		}
	}
	// Old Open API credentials cannot be reused as Cookies; preserve the index for re-login.
	if s.state.Cloud.Account != "" && s.state.Cloud.Cookie == "" {
		if err := s.update(func(st *libraryState) error {
			for id, track := range st.Tracks {
				if track.Remote != nil {
					track.Unavailable = true
					st.Tracks[id] = track
				}
			}
			return nil
		}); err != nil {
			return nil, fmt.Errorf("migrate 115 login: %w", err)
		}
	}
	return s, nil
}

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
	if err := atomicJSON(s.path, next); err != nil {
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
	if err := atomicJSON(s.path, next); err != nil {
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
func (s *Store) duplicateTrack(t Track) (Track, bool) {
	key := func(value string) string { return strings.ToLower(strings.Join(strings.Fields(value), " ")) }
	title, artist := key(t.Title), key(t.Artist)
	if title == "" || artist == "" || artist == "unknown artist" {
		return Track{}, false
	}
	library := t.Library
	if library == "" {
		library = "local"
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, disk := range s.state.Tracks {
		existingLibrary := "local"
		if disk.Remote != nil {
			existingLibrary = "cloud"
		}
		existing := disk.Track
		if existing.ID != t.ID && existingLibrary == library && !existing.Unavailable && existing.MetadataSource != "filename" &&
			key(existing.Title) == title && key(existing.Artist) == artist {
			return existing, true
		}
	}
	return Track{}, false
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
func (s *Store) importedTrack(id string) (Track, bool) {
	if t, ok := s.Track(id); ok {
		return t, true
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, d := range s.state.Tracks {
		for _, previous := range d.PreviousIDs {
			if previous == id {
				t := publicTrack(d)
				t.Path = d.File
				return t, true
			}
		}
	}
	return Track{}, false
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
	return s.update(func(st *libraryState) error {
		for i := range st.Jobs {
			if st.Jobs[i].ID == j.ID {
				st.Jobs[i] = j
				return nil
			}
		}
		st.Jobs = append([]Job{j}, st.Jobs...)
		if len(st.Jobs) > 30 {
			st.Jobs = st.Jobs[:30]
		}
		return nil
	})
}
