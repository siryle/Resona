package resona

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

type Scanner struct {
	config        Config
	store         *Store
	mu            sync.Mutex
	active        bool
	editing       bool
	wg            sync.WaitGroup
	scraper       *Scraper
	catalog       *Catalog
	lyricProvider *LyricsProvider
	logger        *slog.Logger
}

func NewScanner(c Config, store *Store) *Scanner {
	return &Scanner{config: c, store: store, scraper: &Scraper{Client: &http.Client{Timeout: 12 * time.Second}}, catalog: newCatalog(), lyricProvider: &LyricsProvider{Client: &http.Client{Timeout: 15 * time.Second}}, logger: slog.Default()}
}

func (s *Scanner) Start(ctx context.Context, rescrape bool) (Job, error) {
	return s.start(ctx, rescrape, false)
}

func (s *Scanner) StartLibrary(ctx context.Context) (Job, error) {
	return s.start(ctx, false, true)
}

func (s *Scanner) start(ctx context.Context, rescrape, indexOnly bool) (Job, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return Job{}, err
	}
	if s.active || s.editing {
		return Job{}, errors.New("a scan is already running")
	}
	j := Job{ID: randomID(12), State: "running", Phase: "识别音乐文件", Rescrape: rescrape, IndexOnly: indexOnly, StartedAt: time.Now().UTC(), Errors: []string{}}
	task := "整理与刮削任务"
	if indexOnly {
		task, j.Phase = "本地音乐库扫描", "扫描本地音乐文件"
	}
	if err := s.store.putJob(j); err != nil {
		return Job{}, err
	}
	s.logger.Info(task+"已开始", "job", j.ID, "rescrape", rescrape)
	s.active = true
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		defer func() {
			s.mu.Lock()
			s.active = false
			s.mu.Unlock()
		}()
		s.run(ctx, j)
	}()
	return j, nil
}

func (s *Scanner) Wait() { s.wg.Wait() }

func supported(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wav", ".aiff", ".aif", ".alac", ".wma":
		return true
	}
	return false
}

func safeComponent(s string) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || strings.ContainsRune(`/\:*?"<>|`, r) {
			return '_'
		}
		return r
	}, s)
	runes := []rune(strings.Trim(s, " ."))
	// Stay below common 255-byte filesystem component limits with multibyte tags.
	for len(string(runes)) > 120 {
		runes = runes[:len(runes)-1]
	}
	if len(runes) == 0 {
		return "Unknown"
	}
	return string(runes)
}

func hashFile(ctx context.Context, path string) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, &contextReader{ctx: ctx, r: f})
	return hex.EncodeToString(h.Sum(nil)), n, err
}

type contextReader struct {
	ctx context.Context
	r   io.Reader
}

func (r *contextReader) Read(b []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.r.Read(b)
}

func (s *Scanner) copyTrack(ctx context.Context, src string, t Track) (string, error) {
	artist := t.AlbumArtist
	if artist == "" {
		artist = t.Artist
	}
	dir := filepath.Join(s.config.LibraryDir, safeComponent(artist), safeComponent(t.Album))
	resolved, err := musicDirectory(s.config.LibraryDir, dir)
	if err != nil || !within(s.config.LibraryDir, resolved) {
		return "", errors.New("destination escapes library")
	}
	dest, exists, err := s.trackDestination(ctx, resolved, t)
	if err != nil {
		return "", err
	}
	if exists {
		return dest, os.Chmod(dest, 0777)
	}
	in, err := os.Open(src)
	if err != nil {
		return "", err
	}
	defer in.Close()
	out, err := os.CreateTemp(resolved, ".resona-copy-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(out.Name())
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(out, h), &contextReader{ctx: ctx, r: in})
	if err == nil && (n != t.Size || hex.EncodeToString(h.Sum(nil)) != t.ID) {
		err = errors.New("source changed while copying; retry when upload is complete")
	}
	if err == nil {
		err = out.Chmod(0777)
	}
	if err == nil {
		err = out.Sync()
	}
	closeErr := out.Close()
	if err != nil {
		return "", err
	}
	if closeErr != nil {
		return "", closeErr
	}
	// Link publishes a complete file atomically and refuses to overwrite any destination.
	if err := os.Link(out.Name(), dest); err != nil {
		return "", err
	}
	return dest, nil
}

func (s *Scanner) trackDestination(ctx context.Context, dir string, t Track) (string, bool, error) {
	base := safeComponent(t.Title + "-" + t.Artist)
	for _, suffix := range []string{"", " [" + t.ID[:12] + "]"} {
		dest := filepath.Join(dir, base+suffix+"."+t.Format)
		if _, err := os.Lstat(dest); errors.Is(err, os.ErrNotExist) {
			return dest, false, nil
		} else if err != nil {
			return "", false, err
		}
		info, err := os.Lstat(dest)
		if err != nil || !info.Mode().IsRegular() {
			return "", false, errors.New("destination is not a regular file")
		}
		id, _, err := hashFile(ctx, dest)
		if err != nil {
			return "", false, err
		}
		if id == t.ID {
			return dest, true, nil
		}
	}
	return "", false, errors.New("destination exists with different content")
}

func (s *Scanner) renameTrack(ctx context.Context, src string, t Track) (string, error) {
	move, err := s.stageTrackMove(ctx, src, t)
	return move.destination, err
}

func (s *Scanner) extractArtwork(ctx context.Context, src, id string) string {
	return s.extractArt(ctx, src, id, "", false)
}

func (s *Scanner) extractRemoteArtwork(ctx context.Context, src, id, userAgent string) string {
	return s.extractArt(ctx, src, id, userAgent, true)
}

func (s *Scanner) extractArt(ctx context.Context, src, id, userAgent string, replace bool) string {
	dir := filepath.Join(s.config.DataDir, "artwork")
	if err := os.MkdirAll(dir, 0750); err != nil {
		return ""
	}
	path := filepath.Join(dir, id+".jpg")
	if _, err := os.Stat(path); err == nil && !replace {
		return "/api/v1/tracks/" + id + "/cover"
	}
	// ffmpeg decodes embedded art into a bounded, browser-safe JPEG.
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	tmp, err := os.CreateTemp(dir, ".cover-*.jpg")
	if err != nil {
		return ""
	}
	tmp.Close()
	defer os.Remove(tmp.Name())
	args := []string{"-v", "error", "-nostdin", "-y"}
	if userAgent != "" {
		args = append(args, "-protocol_whitelist", "http,https,tls,tcp", "-rw_timeout", "10000000", "-user_agent", userAgent)
	}
	args = append(args, "-i", src, "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=600:600:force_original_aspect_ratio=decrease", "-update", "1", tmp.Name())
	cmd := exec.CommandContext(ctx, "ffmpeg", args...)
	if cmd.Run() != nil {
		return ""
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return ""
	}
	return "/api/v1/tracks/" + id + "/cover"
}

var mbIDPattern = regexp.MustCompile(`^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$`)

func (s *Scanner) onlineArtwork(ctx context.Context, t Track) string {
	if !mbIDPattern.MatchString(t.ReleaseID) {
		return ""
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://coverartarchive.org/release/"+t.ReleaseID+"/front-500", nil)
	if err != nil {
		return ""
	}
	client := &http.Client{Timeout: 12 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return ""
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, (5<<20)+1))
	if err != nil || len(data) > 5<<20 {
		return ""
	}
	if cacheArtwork(filepath.Join(s.config.DataDir, "artwork", t.ID+".jpg"), data) != nil {
		return ""
	}
	return "/api/v1/tracks/" + t.ID + "/cover"
}

func (s *Scanner) copyLyrics(src, dest, root string) error {
	path := strings.TrimSuffix(src, filepath.Ext(src)) + ".lrc"
	real, err := filepath.EvalSymlinks(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || !within(root, real) {
		return errors.New("lyrics file escapes inbox or cannot be read")
	}
	in, err := os.Open(real)
	if err != nil {
		return err
	}
	defer in.Close()
	info, err := in.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxLyricsSize {
		return errors.New("lyrics must be a regular file of at most 1 MiB")
	}
	data, err := io.ReadAll(io.LimitReader(in, (1<<20)+1))
	if err != nil || len(data) > 1<<20 {
		return errors.New("lyrics must be at most 1 MiB")
	}
	path = strings.TrimSuffix(dest, filepath.Ext(dest)) + ".lrc"
	musicDestination := within(s.config.LibraryDir, path) || within(filepath.Join(s.config.DataDir, "cloud115", "strm"), path)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0640)
	if errors.Is(err, os.ErrExist) {
		real, resolveErr := filepath.EvalSymlinks(path)
		info, statErr := os.Stat(path)
		if resolveErr != nil || !within(filepath.Dir(dest), real) || statErr != nil || !info.Mode().IsRegular() || info.Size() > maxLyricsSize {
			return errors.New("destination lyrics are invalid")
		}
		old, readErr := os.ReadFile(real)
		if readErr != nil || !bytes.Equal(old, data) {
			return errors.New("destination lyrics exist with different content")
		}
		if musicDestination {
			return os.Chmod(path, 0777)
		}
		return nil
	}
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil && musicDestination {
		err = f.Chmod(0777)
	}
	closeErr := f.Close()
	if err != nil {
		os.Remove(path)
		return err
	}
	return closeErr
}

func removeUnusedLyrics(path, dest string) error {
	stem := strings.TrimSuffix(path, filepath.Ext(path))
	if stem == strings.TrimSuffix(dest, filepath.Ext(dest)) {
		return nil
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if (supported(entry.Name()) || filepath.Ext(entry.Name()) == ".strm") && strings.EqualFold(
			strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name())), filepath.Base(stem)) {
			// Different formats can share a sidecar; keep it until the last audio file is renamed.
			return nil
		}
	}
	if err := os.Remove(stem + ".lrc"); !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func (s *Scanner) removeImportedSource(ctx context.Context, root, path, sourceID string, original os.FileInfo, track Track) error {
	if root == s.config.LibraryDir || path == track.Path {
		return nil
	}
	for _, location := range []struct{ root, path string }{{root, path}, {s.config.LibraryDir, track.Path}} {
		real, err := filepath.EvalSymlinks(location.path)
		if err != nil || real != location.path || !within(location.root, real) {
			return errors.New("source or destination changed; original retained")
		}
	}
	// Retagging changes the destination hash, so verify against the committed index, not the import hash.
	destID, _, err := hashFile(ctx, track.Path)
	if err != nil || destID != track.ID {
		return errors.New("destination verification failed; original retained")
	}
	if err := s.copyLyrics(path, track.Path, root); err != nil {
		return err
	}
	id, _, err := hashFile(ctx, path)
	current, statErr := os.Lstat(path)
	if err != nil || statErr != nil || !current.Mode().IsRegular() || !os.SameFile(original, current) || id != sourceID ||
		current.Size() != original.Size() || !current.ModTime().Equal(original.ModTime()) {
		return errors.New("source changed during import; original retained")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := os.Remove(path); err != nil {
		return err
	}
	return removeUnusedLyrics(path, track.Path)
}

func (s *Scanner) run(ctx context.Context, j Job) {
	sources := s.store.SourceSettings()
	seen := map[string]bool{}
	lyricsAttempted := map[string]bool{}
	dirtyFrom := len(j.Items)
	markItems := func(index int) {
		if index < dirtyFrom {
			dirtyFrom = index
		}
	}
	report := func(err error) {
		if len(j.Errors) < 100 {
			j.Errors = append(j.Errors, err.Error())
		}
		s.logger.Warn("scan", "job", j.ID, "error", err)
	}
	persist := func() {
		if err := s.store.putJobProgress(j, dirtyFrom); err != nil {
			s.logger.Error("save scan progress", "error", err)
			return
		}
		dirtyFrom = len(j.Items)
	}
	defer func() {
		j.EndedAt = time.Now().UTC()
		switch {
		case ctx.Err() != nil:
			j.State, j.Phase = "interrupted", "扫描已中断"
		case len(j.Errors) > 0:
			j.State, j.Phase = "completed_with_errors", "扫描完成，部分文件需要检查"
		default:
			j.State, j.Phase = "completed", "音乐库已更新"
		}
		persist()
		s.logger.Info("音乐处理任务已结束", "job", j.ID, "index_only", j.IndexOnly, "state", j.State, "processed", j.Processed, "imported", j.Imported, "skipped", j.Skipped)
	}()
	roots := []string{s.config.LibraryDir}
	if !j.IndexOnly {
		roots = append(roots, s.config.InboxDir, s.store.pluginInbox(s.config))
	}
	traversalFailed := false
	for _, root := range roots {
		if root != s.config.LibraryDir && root != s.config.InboxDir {
			if _, err := musicDirectory(root, root); err != nil {
				report(errors.New("无法创建插件收件目录"))
				continue
			}
		}
		err := filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if walkErr != nil {
				traversalFailed = true
				report(fmt.Errorf("%s: %w", filepath.Base(path), walkErr))
				return nil
			}
			if entry.IsDir() {
				if path != root && strings.HasPrefix(entry.Name(), ".") {
					return filepath.SkipDir
				}
				return nil
			}
			if !entry.Type().IsRegular() || !supported(path) || strings.HasPrefix(entry.Name(), ".") {
				return nil
			}
			original, err := entry.Info()
			if err != nil {
				report(err)
				return nil
			}
			s.logger.Debug("处理音乐文件", "file", entry.Name(), "job", j.ID)
			j.Processed++
			j.Phase = "识别 · " + entry.Name()
			detail := JobItem{Filename: entry.Name(), State: "processing", Source: "local"}
			index := len(j.Items)
			j.Items = append(j.Items, detail)
			markItems(index)
			defer func() {
				if ctx.Err() != nil && detail.State == "processing" {
					detail.State, detail.Message = "interrupted", "扫描已中断"
				}
				j.Items[index] = detail
				markItems(index)
				persist()
			}()
			reportItem := func(err error) {
				detail.State = "failed"
				if detail.Message != "" {
					detail.Message += "；"
				}
				detail.Message += err.Error()
				report(err)
			}
			describe := func(t Track) {
				detail.Title, detail.Artist, detail.Album, detail.Duration = t.Title, t.Artist, t.Album, t.Duration
				detail.Source = t.MetadataSource
				if detail.Source == "" {
					detail.Source = "local"
				}
			}
			fillLyrics := func(t Track) Track {
				if j.IndexOnly || lyricsAttempted[t.ID] {
					return t
				}
				j.Phase = "补全歌词 · " + t.Title
				oldID := t.ID
				lyricsAttempted[oldID] = true
				updated, err := s.fillMissingLyrics(ctx, t, sources.Lyrics)
				if err != nil {
					reportItem(fmt.Errorf("%s: 歌词未写入，原文件已保留 (%w)", entry.Name(), err))
					return t
				}
				lyricsAttempted[updated.ID], seen[updated.ID] = true, true
				if updated.ID != oldID {
					for k := range j.Items {
						if j.Items[k].TrackID == oldID {
							j.Items[k].TrackID = updated.ID
						}
					}
					markItems(0)
				}
				return updated
			}
			if j.Processed%10 == 1 {
				persist()
			}
			id, size, err := hashFile(ctx, path)
			if err != nil {
				reportItem(fmt.Errorf("%s: %w", entry.Name(), err))
				return nil
			}
			existing, found, err := s.store.importedTrack(id)
			if err != nil {
				reportItem(err)
				return nil
			}
			if found {
				detail.TrackID = existing.ID
				describe(existing)
				if _, err := os.Stat(existing.Path); err == nil && (existing.ID != id || !j.Rescrape || seen[id]) {
					j.Skipped++
					describe(existing)
					detail.TrackID, detail.State, detail.Message = existing.ID, "skipped", "文件内容相同，保留已有曲目"
					existing = fillLyrics(existing)
					detail.TrackID = existing.ID
					if !j.IndexOnly && detail.State != "failed" && root != s.config.LibraryDir {
						if err := s.removeImportedSource(ctx, root, path, id, original, existing); err != nil {
							reportItem(fmt.Errorf("%s: 来源文件清理失败 (%w)", entry.Name(), err))
						}
					}
					if detail.State == "failed" {
						detail.State = "imported_with_warnings"
					}
					return nil
				}
			}
			seen[id] = true
			t, err := readMetadata(ctx, path)
			if err != nil {
				reportItem(fmt.Errorf("%s: %w", entry.Name(), err))
				return nil
			}
			t.ID, t.Size, t.AddedAt = id, size, time.Now().UTC()
			if old, ok := s.store.Track(id); ok && old.MetadataLocked {
				metadataOf(old).apply(&t)
				t.MetadataLocked = true
			}
			if !j.IndexOnly && s.config.Scrape && !t.MetadataLocked {
				j.Phase = "刮削 · " + t.Title
				describe(t)
				j.Items[index] = detail
				markItems(index)
				persist()
				if err := s.enrich(ctx, &t, sources.Metadata); err != nil {
					reportItem(fmt.Errorf("%s: 刮削未成功，保留本地标签 (%w)", entry.Name(), err))
				} else {
					s.logger.Info("元数据识别已完成", "title", t.Title, "source", t.MetadataSource, "duration", t.Duration)
				}
			}
			if t.Artist == "" {
				t.Artist = "Unknown Artist"
			}
			if t.Album == "" {
				t.Album = "Unknown Album"
			}
			if t.AlbumArtist == "" {
				t.AlbumArtist = t.Artist
			}
			describe(t)
			if !j.IndexOnly {
				if duplicate, ok, err := s.store.duplicateTrack(t); err != nil {
					reportItem(err)
					return nil
				} else if ok {
					j.Skipped++
					detail.TrackID, detail.State, detail.Message = duplicate.ID, "skipped", "同一音乐库已有同名同歌手歌曲，保留来源文件"
					return nil
				}
			}
			dest := path
			if root != s.config.LibraryDir {
				j.Phase = "整理 · " + t.Title
				dest, err = s.copyTrack(ctx, path, t)
				if err != nil {
					reportItem(fmt.Errorf("%s: %w", entry.Name(), err))
					return nil
				}
				if err := s.copyLyrics(path, dest, root); err != nil {
					reportItem(fmt.Errorf("%s: %w", entry.Name(), err))
				}
			} else if j.Rescrape {
				dest, err = s.renameTrack(ctx, path, t)
				if err != nil {
					reportItem(fmt.Errorf("%s: %w", entry.Name(), err))
					return nil
				}
			}
			t.Artwork = s.extractArtwork(ctx, dest, id)
			if t.Artwork == "" {
				for _, name := range []string{"cover.jpg", "folder.jpg", "cover.png", "folder.png"} {
					cover := filepath.Join(filepath.Dir(path), name)
					if real, err := filepath.EvalSymlinks(cover); err == nil && within(root, real) {
						t.Artwork = s.extractArtwork(ctx, real, id)
						if t.Artwork != "" {
							break
						}
					}
				}
			}
			if t.Artwork == "" && s.config.Scrape && !j.IndexOnly {
				t.Artwork = s.onlineArtwork(ctx, t)
			}
			err = s.store.updateEntry(id, func(st *libraryState) error {
				var lyrics *SavedLyrics
				var previousIDs []string
				if old, ok := st.Tracks[id]; ok {
					previousIDs = old.PreviousIDs
					t.Favorite, t.AddedAt = old.Favorite, old.AddedAt
					lyrics = old.Lyrics
					// A correction may have been saved while this file was being scanned.
					if old.MetadataLocked {
						metadataOf(old.Track).apply(&t)
						t.MetadataLocked = true
					}
					if lyricsIdentity(old.Track) != lyricsIdentity(t) {
						lyrics = nil
					}
				}
				embedded, _ := makeLyrics(t.TagLyrics, "embedded")
				st.Tracks[id] = DiskTrack{Track: t, File: dest, Lyrics: lyrics, EmbeddedLyrics: embedded, EmbeddedChecked: true, PreviousIDs: previousIDs}
				return nil
			})
			if err != nil {
				reportItem(err)
				return nil
			}
			j.Imported++
			if root == s.config.LibraryDir && dest != path {
				// Publish the new index first so a failed rename never loses the only indexed copy.
				if err := os.Remove(path); err != nil {
					reportItem(fmt.Errorf("%s: 旧文件清理失败 (%w)", entry.Name(), err))
				} else if err := removeUnusedLyrics(path, dest); err != nil {
					reportItem(fmt.Errorf("%s: 旧歌词清理失败 (%w)", entry.Name(), err))
				}
			}
			t, _ = s.store.Track(id)
			t = fillLyrics(t)
			if detail.Message == "" && root != s.config.LibraryDir {
				if err := s.removeImportedSource(ctx, root, path, id, original, t); err != nil {
					reportItem(fmt.Errorf("%s: 来源文件清理失败 (%w)", entry.Name(), err))
				}
			}
			describe(t)
			detail.TrackID, detail.State = t.ID, "imported"
			if detail.Message != "" {
				detail.State = "imported_with_warnings"
			}
			return nil
		})
		if err != nil {
			if ctx.Err() == nil {
				report(err)
			}
			return
		}
	}
	if traversalFailed {
		return
	}
	// Only prune after a successful traversal; temporary storage outages keep the index intact.
	if err := s.store.update(func(st *libraryState) error {
		for id, t := range st.Tracks {
			if t.Remote != nil {
				continue
			}
			if _, err := os.Stat(t.File); errors.Is(err, os.ErrNotExist) {
				delete(st.Tracks, id)
			}
		}
		return nil
	}); err != nil {
		report(err)
	}
}

func trackFileName(t Track) string {
	return safeComponent(t.Artist+" - "+t.Title) + "." + t.Format
}

func parsePositive(s string, fallback int) int {
	n, err := strconv.Atoi(s)
	if err != nil || n < 1 {
		return fallback
	}
	return n
}
