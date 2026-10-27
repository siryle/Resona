package resona

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/rand/v2"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	root "resona"
)

const maxLyricsSize = 1 << 20

var (
	errNoLyrics     = errors.New("没有找到匹配歌词，请检查歌曲名称、艺术家和版本")
	errLyricsExist  = errors.New("已有歌词；如需重新获取，请勾选替换现有歌词")
	errTrackChanged = errors.New("歌曲信息已变化，请刷新后重试")
	errLyricsBusy   = errors.New("歌词服务繁忙，请稍后重试")
)

type SavedLyrics struct {
	Text      string    `json:"text"`
	Source    string    `json:"source"`
	Synced    bool      `json:"synced"`
	FetchedAt time.Time `json:"fetched_at,omitempty"`
}

var lyricTimestamp = regexp.MustCompile(`\[\d+:[0-5]\d(?:[.:]\d{1,3})?\]`)

func makeLyrics(text, source string) (*SavedLyrics, error) {
	text = strings.TrimSpace(strings.TrimPrefix(text, "\ufeff"))
	if text == "" {
		return nil, errNoLyrics
	}
	if len(text) > maxLyricsSize || !utf8.ValidString(text) || strings.ContainsRune(text, 0) {
		return nil, errors.New("歌词内容无效或超过 1 MiB")
	}
	return &SavedLyrics{Text: text, Source: source, Synced: lyricTimestamp.MatchString(text), FetchedAt: time.Now().UTC()}, nil
}

type lyricSignature struct {
	Title, Artist, Album string
	Duration             float64
}

func lyricsIdentity(t Track) lyricSignature {
	return lyricSignature{t.Title, t.Artist, t.Album, t.Duration}
}

type LyricsProvider struct {
	Client   *http.Client
	Endpoint string
	mu       sync.Mutex
	next     time.Time
}

func (p *LyricsProvider) Fetch(ctx context.Context, t Track) (*SavedLyrics, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if delay := time.Until(p.next); delay > 0 {
		if delay > time.Second {
			return nil, errLyricsBusy
		}
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
	query := url.Values{"track_name": {t.Title}, "artist_name": {t.Artist}}
	if t.Album != "" && t.Album != "Unknown Album" {
		query.Set("album_name", t.Album)
	}
	if t.Duration >= 1 && t.Duration <= 3600 {
		query.Set("duration", strconv.FormatFloat(math.Round(t.Duration), 'f', 0, 64))
	}
	endpoint := p.Endpoint
	if endpoint == "" {
		endpoint = "https://lrclib.net/api/get"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint+"?"+query.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Resona/"+root.Version().Version+" (self-hosted music library)")
	req.Header.Set("Accept", "application/json")
	resp, err := p.Client.Do(req)
	p.next = time.Now().Add(500 * time.Millisecond)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 429 || resp.StatusCode == 503 {
		retry := time.Now().Add(time.Minute)
		if seconds, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && seconds > 0 {
			retry = time.Now().Add(time.Duration(seconds) * time.Second)
		} else if date, err := http.ParseTime(resp.Header.Get("Retry-After")); err == nil && date.After(time.Now()) {
			retry = date
		}
		p.next = retry.Add(time.Duration(rand.IntN(1000)) * time.Millisecond)
		return nil, errLyricsBusy
	}
	if resp.StatusCode == 404 {
		return nil, errNoLyrics
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("LRCLIB HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, (4<<20)+1))
	if err != nil || len(data) > 4<<20 {
		return nil, errors.New("歌词服务响应过大或读取失败")
	}
	var result struct {
		Title        string  `json:"trackName"`
		Artist       string  `json:"artistName"`
		Album        string  `json:"albumName"`
		Duration     float64 `json:"duration"`
		Instrumental bool    `json:"instrumental"`
		Synced       string  `json:"syncedLyrics"`
		Plain        string  `json:"plainLyrics"`
	}
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, err
	}
	if normalize(t.Title) == "" || normalize(t.Artist) == "" ||
		normalize(t.Title) != normalize(result.Title) || normalize(t.Artist) != normalize(result.Artist) ||
		result.Duration <= 0 || abs(t.Duration-result.Duration) > 2 ||
		(query.Has("album_name") && normalize(t.Album) != normalize(result.Album)) {
		return nil, errNoLyrics
	}
	text := strings.TrimSpace(result.Synced)
	synced := text != ""
	if !synced {
		text = strings.TrimSpace(result.Plain)
	}
	if result.Instrumental || text == "" {
		return nil, errNoLyrics
	}
	if len(text) > maxLyricsSize || !utf8.ValidString(text) || strings.ContainsRune(text, 0) {
		return nil, errors.New("歌词内容无效或超过 1 MiB")
	}
	return &SavedLyrics{Text: text, Source: "LRCLIB", Synced: synced, FetchedAt: time.Now().UTC()}, nil
}

func (s *Scanner) localLyrics(t Track) (*SavedLyrics, error) {
	path := strings.TrimSuffix(t.Path, filepath.Ext(t.Path)) + ".lrc"
	real, err := filepath.EvalSymlinks(path)
	root := s.config.LibraryDir
	if t.Library == "cloud" {
		root = filepath.Join(s.config.DataDir, "cloud115", "strm")
	}
	if err != nil || !within(root, real) {
		return nil, os.ErrNotExist
	}
	f, err := os.Open(real)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxLyricsSize {
		return nil, errors.New("本地歌词文件无效或超过 1 MiB")
	}
	data, err := io.ReadAll(io.LimitReader(f, maxLyricsSize+1))
	if err != nil || len(data) > maxLyricsSize {
		return nil, errors.New("读取本地歌词失败")
	}
	if strings.TrimSpace(string(data)) == "" {
		return nil, os.ErrNotExist
	}
	return &SavedLyrics{Text: string(data), Source: "local", Synced: true}, nil
}

func (s *Scanner) readLyrics(ctx context.Context, t Track) (*SavedLyrics, error) {
	s.store.mu.RLock()
	disk := s.store.state.Tracks[t.ID]
	s.store.mu.RUnlock()
	if disk.Lyrics != nil {
		return disk.Lyrics, nil
	}
	if local, err := s.localLyrics(t); !errors.Is(err, os.ErrNotExist) {
		return local, err
	}
	if disk.EmbeddedChecked {
		if disk.EmbeddedLyrics != nil {
			return disk.EmbeddedLyrics, nil
		}
		return nil, os.ErrNotExist
	}
	return s.cacheEmbeddedLyrics(ctx, t)
}

func (s *Scanner) cacheEmbeddedLyrics(ctx context.Context, t Track) (*SavedLyrics, error) {
	// Older indexes did not record embedded lyrics; read them once without requiring a reimport.
	path, err := filepath.EvalSymlinks(t.Path)
	if err != nil || !within(s.config.LibraryDir, path) {
		return nil, os.ErrNotExist
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return nil, os.ErrNotExist
	}
	metadata, err := readMetadata(ctx, path)
	if err != nil {
		return nil, os.ErrNotExist
	}
	embedded, _ := makeLyrics(metadata.TagLyrics, "embedded")
	if err := s.store.update(func(st *libraryState) error {
		current, ok := st.Tracks[t.ID]
		if !ok || current.File != t.Path {
			return errTrackChanged
		}
		current.EmbeddedLyrics, current.EmbeddedChecked = embedded, true
		st.Tracks[t.ID] = current
		return nil
	}); err != nil {
		s.logger.Info("cache embedded lyrics", "error", err)
	}
	if embedded != nil {
		return embedded, nil
	}
	return nil, os.ErrNotExist
}

func (s *Server) scrapeLyrics(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Replace bool   `json:"replace"`
		Source  string `json:"source"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	if body.Source == "" {
		body.Source = s.store.SourceSettings().Lyrics
	}
	if !validSource(body.Source, true) {
		apiError(w, 400, "不支持的歌词源")
		return
	}
	t, ok := s.store.Track(r.PathValue("id"))
	if !ok {
		apiError(w, 404, "track not found")
		return
	}
	if !body.Replace {
		if _, err := s.scanner.readLyrics(r.Context(), t); err == nil {
			apiError(w, 409, errLyricsExist.Error())
			return
		} else if !errors.Is(err, os.ErrNotExist) {
			apiError(w, 409, "无法读取现有歌词，请检查文件后重试")
			return
		}
	}
	lyrics, err := s.scanner.fetchLyrics(r.Context(), body.Source, t)
	if errors.Is(err, errLyricsBusy) {
		s.scanner.lyricProvider.mu.Lock()
		delay := max(1, int(math.Ceil(time.Until(s.scanner.lyricProvider.next).Seconds())))
		s.scanner.lyricProvider.mu.Unlock()
		if body.Source != "lrclib" {
			delay = max(delay, s.scanner.catalog.retryAfter())
		}
		w.Header().Set("Retry-After", strconv.Itoa(delay))
		apiError(w, 429, err.Error())
		return
	}
	if errors.Is(err, errNoLyrics) {
		apiError(w, 404, err.Error())
		return
	}
	if err != nil {
		s.scanner.logger.Info("fetch lyrics", "error", err)
		apiError(w, 502, "歌词服务暂时不可用，请稍后重试")
		return
	}
	err = s.store.update(func(st *libraryState) error {
		current, ok := st.Tracks[t.ID]
		if !ok {
			return os.ErrNotExist
		}
		if lyricsIdentity(current.Track) != lyricsIdentity(t) {
			return errTrackChanged
		}
		if !body.Replace {
			if current.Lyrics != nil || current.EmbeddedLyrics != nil {
				return errLyricsExist
			}
			local := current.Track
			local.Path = current.File
			if _, localErr := s.scanner.localLyrics(local); !errors.Is(localErr, os.ErrNotExist) {
				return errLyricsExist
			}
		}
		current.Lyrics = lyrics
		st.Tracks[t.ID] = current
		return nil
	})
	switch {
	case errors.Is(err, os.ErrNotExist):
		apiError(w, 404, "track not found")
	case errors.Is(err, errTrackChanged), errors.Is(err, errLyricsExist):
		apiError(w, 409, err.Error())
	case err != nil:
		s.scanner.logger.Error("save lyrics", "error", err)
		apiError(w, 500, "无法保存歌词")
	default:
		s.scanner.logger.Info("歌词刮削已完成", "track", t.ID, "source", lyrics.Source)
		jsonResponse(w, 200, lyrics)
	}
}

func (s *Scanner) fetchLyrics(ctx context.Context, source string, t Track) (*SavedLyrics, error) {
	ids := []string{source}
	if source == "auto" {
		ids = s.store.SourceSettings().lyricsOrder()
	}
	var failures []error
	for _, id := range ids {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var lyric *SavedLyrics
		var err error
		if id == "lrclib" {
			lyric, err = s.lyricProvider.Fetch(ctx, t)
		} else {
			lyric, err = s.catalog.FetchLyrics(ctx, id, t)
		}
		if err == nil {
			return lyric, nil
		}
		s.logger.Debug("歌词源未匹配，继续尝试下一来源", "source", sourceName(id), "track", t.ID, "error", err)
		if !errors.Is(err, errNoLyrics) {
			failures = append(failures, err)
		}
	}
	if len(failures) > 0 {
		return nil, errors.Join(failures...)
	}
	return nil, errNoLyrics
}
