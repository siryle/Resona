package resona

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

var (
	errLibraryBusy   = errors.New("扫描或标签写入正在进行，请等待完成后重试")
	errEmbeddedExist = errors.New("音频标签已有歌词，请确认后勾选覆盖标签歌词")
	errEmbedFormat   = errors.New("暂仅支持将歌词写入 MP3、FLAC、M4A、OGG 和 Opus 标签")
)

func (s *Server) embedLyrics(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Replace bool `json:"replace"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	t, err := s.embedTrackLyrics(r.Context(), r.PathValue("id"), body.Replace)
	switch {
	case errors.Is(err, os.ErrNotExist):
		apiError(w, 404, "歌曲或歌词不存在")
	case errors.Is(err, errEmbedFormat):
		apiError(w, 415, err.Error())
	case errors.Is(err, errEmbeddedExist), errors.Is(err, errLibraryBusy), errors.Is(err, errTrackChanged):
		apiError(w, 409, err.Error())
	case err != nil:
		s.scanner.logger.Error("embed lyrics", "error", err)
		apiError(w, 500, "歌词写入未完成，原音频已保留，请检查格式和目录权限")
	default:
		jsonResponse(w, 200, s.trackWithLRC(t))
	}
}

func (s *Server) embedTrackLyrics(ctx context.Context, id string, replace bool) (Track, error) {
	s.scanner.mu.Lock()
	if s.scanner.active || s.scanner.editing {
		s.scanner.mu.Unlock()
		return Track{}, errLibraryBusy
	}
	s.scanner.editing = true
	s.scanner.mu.Unlock()
	defer func() {
		s.scanner.mu.Lock()
		s.scanner.editing = false
		s.scanner.mu.Unlock()
	}()
	return s.scanner.embedTrackLyrics(ctx, id, replace)
}

// The caller serializes library edits with scans.
func (s *Scanner) embedTrackLyrics(ctx context.Context, id string, replace bool) (Track, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	t, ok := s.store.Track(id)
	if !ok {
		return Track{}, os.ErrNotExist
	}
	if t.Library == "cloud" {
		return Track{}, errEmbedFormat
	}
	s.store.mu.RLock()
	before := s.store.state.Tracks[id]
	s.store.mu.RUnlock()
	if before.File != t.Path || metadataOf(before.Track) != metadataOf(t) {
		return Track{}, errTrackChanged
	}
	switch strings.ToLower(filepath.Ext(t.Path)) {
	case ".mp3", ".flac", ".m4a", ".ogg", ".opus":
	default:
		return Track{}, errEmbedFormat
	}
	path, err := filepath.EvalSymlinks(t.Path)
	if err != nil || !within(s.config.LibraryDir, path) {
		return Track{}, errors.New("audio path escapes library or is unavailable")
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return Track{}, errors.New("audio is not a regular file")
	}
	actualID, _, err := hashFile(ctx, path)
	if err != nil || actualID != id {
		return Track{}, errTrackChanged
	}
	// Read real tags, not the cached badge, before asking to overwrite embedded lyrics.
	metadata, err := readMetadata(ctx, path)
	if err != nil {
		return Track{}, err
	}
	if metadata.TagLyrics != "" && !replace {
		return Track{}, errEmbeddedExist
	}
	lyrics, err := s.readLyrics(ctx, t)
	if err != nil {
		return Track{}, err
	}
	lyrics, err = makeLyrics(lyrics.Text, "embedded")
	if err != nil {
		return Track{}, err
	}
	// Metadata is a separate input to avoid OS argument length limits for large LRC files.
	tags, err := os.CreateTemp(filepath.Dir(path), ".resona-lyrics-*.txt")
	if err != nil {
		return Track{}, err
	}
	defer os.Remove(tags.Name())
	escape := strings.NewReplacer("\\", "\\\\", "=", "\\=", ";", "\\;", "#", "\\#", "\n", "\\\n", "\r", "\\\r")
	_, err = fmt.Fprint(tags, ";FFMETADATA1\nlyrics=", escape.Replace(lyrics.Text), "\n")
	closeErr := tags.Close()
	if err != nil {
		return Track{}, err
	}
	if closeErr != nil {
		return Track{}, closeErr
	}
	out, err := os.CreateTemp(filepath.Dir(path), ".resona-tags-*"+filepath.Ext(path))
	if err != nil {
		return Track{}, err
	}
	staged := out.Name()
	out.Close()
	defer os.Remove(staged)
	args := []string{"-v", "error", "-nostdin", "-y", "-i", path, "-f", "ffmetadata", "-i", tags.Name()}
	if strings.EqualFold(filepath.Ext(path), ".mp3") {
		// MP3 accepts one audio stream and cover pictures, not arbitrary extra streams.
		args = append(args, "-map", "0:a:0", "-map", "0:v?", "-c", "copy", "-id3v2_version", "3")
	} else {
		args = append(args, "-map", "0", "-c", "copy")
	}
	args = append(args, "-map_metadata", "1", "-map_metadata", "0", staged)
	cmd := exec.CommandContext(ctx, "ffmpeg", args...)
	if _, err := cmd.Output(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return Track{}, fmt.Errorf("remux lyrics: %w: %.2048s", err, strings.TrimSpace(string(exit.Stderr)))
		}
		return Track{}, fmt.Errorf("remux lyrics: %w", err)
	}
	verified, err := readMetadata(ctx, staged)
	if err != nil || verified.TagLyrics != lyrics.Text || abs(verified.Duration-metadata.Duration) > 0.1 {
		return Track{}, errors.New("remuxed file did not pass lyrics/duration verification")
	}
	if actualID, _, err := hashFile(ctx, path); err != nil || actualID != id {
		return Track{}, errTrackChanged
	}
	newID, size, err := hashFile(ctx, staged)
	if err != nil {
		return Track{}, err
	}
	if newID == id {
		if _, err := s.cacheEmbeddedLyrics(ctx, t); err != nil {
			return Track{}, err
		}
		updated, _ := s.store.Track(id)
		return updated, nil
	}
	file, err := os.OpenFile(staged, os.O_RDWR, 0)
	if err != nil {
		return Track{}, err
	}
	err = file.Chmod(0777)
	if err == nil {
		err = file.Sync()
	}
	closeErr = file.Close()
	if err != nil {
		return Track{}, err
	}
	if closeErr != nil {
		return Track{}, closeErr
	}
	backup := lyricsBackup(path, id)
	if err := os.Link(path, backup); err != nil {
		return Track{}, err
	}
	replaced := false
	var createdArtwork string
	defer func() {
		if !replaced || err == nil {
			os.Remove(backup)
		}
	}()
	err = s.store.updateWithRollback(func(st *libraryState) error {
		current, ok := st.Tracks[id]
		if !ok || current.File != t.Path || metadataOf(current.Track) != metadataOf(before.Track) || current.Lyrics != before.Lyrics {
			return errTrackChanged
		}
		if _, ok := st.Tracks[newID]; ok {
			return errTrackChanged
		}
		current.ID, current.Size = newID, size
		current.EmbeddedLyrics, current.EmbeddedChecked = lyrics, true
		current.PreviousIDs = append(append([]string{}, current.PreviousIDs...), id)
		if current.Artwork != "" {
			old := filepath.Join(s.config.DataDir, "artwork", id+".jpg")
			art := filepath.Join(s.config.DataDir, "artwork", newID+".jpg")
			if err := os.Link(old, art); err != nil {
				if !errors.Is(err, os.ErrExist) {
					return err
				}
			} else {
				createdArtwork = art
			}
			current.Artwork = "/api/v1/tracks/" + newID + "/cover"
		}
		delete(st.Tracks, id)
		st.Tracks[newID] = current
		for i, job := range st.Jobs {
			items := append([]JobItem{}, job.Items...)
			for k := range items {
				if items[k].TrackID == id {
					items[k].TrackID = newID
				}
			}
			st.Jobs[i].Items = items
		}
		if err := os.Rename(staged, path); err != nil {
			return err
		}
		replaced = true
		return nil
	}, func() error {
		if createdArtwork != "" {
			os.Remove(createdArtwork)
		}
		if replaced {
			restoreErr := os.Rename(backup, path)
			if restoreErr == nil {
				replaced = false
			}
			return restoreErr
		}
		return nil
	})
	if err != nil {
		return Track{}, err
	}
	s.logger.Info("歌词已写入歌曲标签", "track", newID, "file", filepath.Base(path))
	updated, _ := s.store.Track(newID)
	return updated, nil
}

func lyricsBackup(path, id string) string {
	return filepath.Join(filepath.Dir(path), ".resona-original-"+id+filepath.Ext(path))
}

// Scans fill empty tags only; existing embedded lyrics always remain authoritative.
func (s *Scanner) fillMissingLyrics(ctx context.Context, t Track, source string) (Track, error) {
	if t.HasEmbeddedLyrics == nil {
		if _, err := s.cacheEmbeddedLyrics(ctx, t); err != nil && !errors.Is(err, os.ErrNotExist) {
			return t, err
		}
		t, _ = s.store.Track(t.ID)
	}
	if t.HasEmbeddedLyrics != nil && *t.HasEmbeddedLyrics {
		return t, nil
	}
	switch strings.ToLower(filepath.Ext(t.Path)) {
	case ".mp3", ".flac", ".m4a", ".ogg", ".opus":
	default:
		return t, nil
	}
	_, err := s.readLyrics(ctx, t)
	if errors.Is(err, os.ErrNotExist) {
		if !s.config.Scrape {
			return t, nil
		}
		lyric, fetchErr := s.fetchLyrics(ctx, source, t)
		if fetchErr != nil {
			return t, fetchErr
		}
		err = s.store.updateEntry(t.ID, func(st *libraryState) error {
			current, ok := st.Tracks[t.ID]
			if !ok || lyricsIdentity(current.Track) != lyricsIdentity(t) {
				return errTrackChanged
			}
			if current.Lyrics == nil {
				current.Lyrics = lyric
				st.Tracks[t.ID] = current
			}
			return nil
		})
	}
	if err != nil {
		return t, err
	}
	updated, err := s.embedTrackLyrics(ctx, t.ID, false)
	if err != nil {
		return t, err
	}
	return updated, nil
}
