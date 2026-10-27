package resona

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	root "resona"
)

type SourceSettings struct {
	Metadata         string   `json:"metadata"`
	Lyrics           string   `json:"lyrics"`
	MetadataPriority []string `json:"metadata_priority"`
	MetadataDisabled []string `json:"metadata_disabled"`
	LyricsPriority   []string `json:"lyrics_priority"`
	LyricsDisabled   []string `json:"lyrics_disabled"`
}

var defaultMetadataPriority = []string{"qq", "netease", "kugou", "musicbrainz", "itunes", "migu", "kuwo", "smart_tag"}
var defaultMetadataDisabled = []string{"smart_tag"}
var defaultLyricsPriority = []string{"lrclib", "qq", "netease", "kugou"}
var errNoMetadata = errors.New("没有可信的匹配结果")

func (p SourceSettings) metadataOrder() []string {
	priority := p.MetadataPriority
	if len(priority) == 0 {
		priority = defaultMetadataPriority
	}
	ids := []string{}
	for _, id := range priority {
		disabled := false
		for _, excluded := range p.MetadataDisabled {
			disabled = disabled || id == excluded
		}
		if !disabled {
			ids = append(ids, id)
		}
	}
	return ids
}

func (p SourceSettings) lyricsOrder() []string {
	priority := p.LyricsPriority
	if len(priority) == 0 {
		priority = defaultLyricsPriority
	}
	ids := []string{}
	for _, id := range priority {
		if !slices.Contains(p.LyricsDisabled, id) {
			ids = append(ids, id)
		}
	}
	return ids
}

type MusicSource struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Metadata    bool   `json:"metadata"`
	Lyrics      bool   `json:"lyrics"`
	Requirement string `json:"requirement,omitempty"`
}

var musicSources = []MusicSource{
	{ID: "musicbrainz", Name: "MusicBrainz", Metadata: true},
	{ID: "qq", Name: "QQ音乐", Metadata: true, Lyrics: true},
	{ID: "netease", Name: "网易云音乐", Metadata: true, Lyrics: true},
	{ID: "kugou", Name: "酷狗音乐", Metadata: true, Lyrics: true},
	{ID: "itunes", Name: "iTunes", Metadata: true},
	{ID: "lrclib", Name: "LRCLIB", Lyrics: true},
	{ID: "migu", Name: "咪咕音乐", Metadata: true},
	{ID: "kuwo", Name: "酷我音乐", Metadata: true},
	{ID: "smart_tag", Name: "智能标签源", Metadata: true, Requirement: "综合已启用来源并按歌曲信息匹配排序"},
}

func validSource(id string, lyrics bool) bool {
	if id == "auto" {
		return true
	}
	for _, s := range musicSources {
		if s.ID == id && ((lyrics && s.Lyrics) || (!lyrics && s.Metadata)) {
			return true
		}
	}
	return false
}

func sourceName(id string) string {
	for _, s := range musicSources {
		if s.ID == id {
			return s.Name
		}
	}
	switch id {
	case "auto":
		return "自动选择"
	case "manual":
		return "人工更正"
	case "local":
		return "本地标签"
	case "embedded":
		return "内嵌歌词"
	}
	return id
}

func (s *Store) SourceSettings() SourceSettings {
	s.mu.RLock()
	defer s.mu.RUnlock()
	p := s.state.Sources
	if p.Metadata == "" {
		p.Metadata = "musicbrainz"
	}
	if p.Lyrics == "" {
		p.Lyrics = "lrclib"
	}
	p.MetadataPriority = append([]string{}, p.MetadataPriority...)
	if len(p.MetadataPriority) == 0 {
		p.MetadataPriority = append(p.MetadataPriority, defaultMetadataPriority...)
	}
	if p.MetadataDisabled == nil {
		p.MetadataDisabled = defaultMetadataDisabled
	}
	p.MetadataDisabled = append([]string{}, p.MetadataDisabled...)
	p.LyricsPriority = append([]string{}, p.LyricsPriority...)
	if len(p.LyricsPriority) == 0 {
		p.LyricsPriority = append(p.LyricsPriority, defaultLyricsPriority...)
	}
	p.LyricsDisabled = append([]string{}, p.LyricsDisabled...)
	return p
}

func (s *Server) sources(w http.ResponseWriter, r *http.Request) {
	jsonResponse(w, 200, map[string]any{"items": musicSources, "settings": s.store.SourceSettings()})
}

func (s *Server) saveSources(w http.ResponseWriter, r *http.Request) {
	var body SourceSettings
	if !decodeBody(w, r, &body) {
		return
	}
	if !validSource(body.Metadata, false) || !validSource(body.Lyrics, true) {
		apiError(w, 400, "不支持的刮削源或歌词源")
		return
	}
	if body.MetadataPriority != nil {
		seen := map[string]bool{}
		for _, id := range body.MetadataPriority {
			if id == "auto" || !validSource(id, false) || seen[id] {
				apiError(w, 400, "刮削优先级必须包含所有刮削源，且不能重复")
				return
			}
			seen[id] = true
		}
		if len(seen) != len(defaultMetadataPriority) {
			apiError(w, 400, "刮削优先级必须包含所有刮削源")
			return
		}
	}
	if body.MetadataDisabled != nil {
		seen := map[string]bool{}
		for _, id := range body.MetadataDisabled {
			if id == "auto" || !validSource(id, false) || seen[id] {
				apiError(w, 400, "禁用列表包含无效或重复的刮削源")
				return
			}
			seen[id] = true
		}
		if len(seen) == len(defaultMetadataPriority) {
			apiError(w, 400, "请至少启用一个刮削源")
			return
		}
		if len(seen) == len(defaultMetadataPriority)-1 && !seen["smart_tag"] {
			apiError(w, 400, "智能标签源需要至少启用一个普通刮削源")
			return
		}
	}
	if body.LyricsPriority != nil {
		seen := map[string]bool{}
		for _, id := range body.LyricsPriority {
			if id == "auto" || !validSource(id, true) || seen[id] {
				apiError(w, 400, "歌词优先级必须包含所有歌词源，且不能重复")
				return
			}
			seen[id] = true
		}
		if len(seen) != len(defaultLyricsPriority) {
			apiError(w, 400, "歌词优先级必须包含所有歌词源")
			return
		}
	}
	if body.LyricsDisabled != nil {
		seen := map[string]bool{}
		for _, id := range body.LyricsDisabled {
			if id == "auto" || !validSource(id, true) || seen[id] {
				apiError(w, 400, "禁用列表包含无效或重复的歌词源")
				return
			}
			seen[id] = true
		}
		if len(seen) == len(defaultLyricsPriority) {
			apiError(w, 400, "请至少启用一个歌词源")
			return
		}
	}
	if err := s.store.update(func(st *libraryState) error {
		if body.MetadataPriority == nil {
			body.MetadataPriority = st.Sources.MetadataPriority
		}
		if body.MetadataDisabled == nil {
			body.MetadataDisabled = st.Sources.MetadataDisabled
		}
		if body.LyricsPriority == nil {
			body.LyricsPriority = st.Sources.LyricsPriority
		}
		if body.LyricsDisabled == nil {
			body.LyricsDisabled = st.Sources.LyricsDisabled
		}
		st.Sources = body
		return nil
	}); err != nil {
		apiError(w, 500, "无法保存来源设置")
		return
	}
	s.logger.With("category", "settings").Info("刮削源、歌词源与优先级设置已保存", "metadata", body.Metadata, "lyrics", body.Lyrics, "metadata_priority", body.MetadataPriority, "metadata_disabled", body.MetadataDisabled, "lyrics_priority", body.LyricsPriority, "lyrics_disabled", body.LyricsDisabled)
	s.sources(w, r)
}

type MetadataCandidate struct {
	TrackMetadata
	SourceID string  `json:"source_id,omitempty"`
	Duration float64 `json:"duration"`
	Score    int     `json:"score,omitempty"`
}

type Catalog struct {
	Client    *http.Client
	Endpoints map[string]string // Only overridden by local test fixtures.
	mu        sync.Mutex
	next      map[string]time.Time
}

func newCatalog() *Catalog {
	return &Catalog{Client: &http.Client{Timeout: 12 * time.Second}, next: map[string]time.Time{}}
}

func (c *Catalog) get(ctx context.Context, source, endpoint string, query url.Values, body url.Values, out any) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.next == nil {
		c.next = map[string]time.Time{}
	}
	if delay := time.Until(c.next[source]); delay > 0 {
		if delay > time.Second {
			return errLyricsBusy
		}
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
		}
	}
	if replacement := c.Endpoints[endpoint]; replacement != "" {
		endpoint = replacement
	}
	method := http.MethodGet
	var data io.Reader
	if body != nil {
		method, data = http.MethodPost, strings.NewReader(body.Encode())
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint+"?"+query.Encode(), data)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Resona/"+root.Version().Version+" (self-hosted music library)")
	req.Header.Set("Accept", "application/json")
	if source == "qq" {
		req.Header.Set("Referer", "https://y.qq.com/")
	} else if source == "netease" {
		req.Header.Set("Referer", "https://music.163.com/")
	} else if source == "migu" {
		req.Header.Set("Referer", "https://m.music.migu.cn/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
	} else if source == "kuwo" {
		req.Header.Set("Referer", "https://www.kuwo.cn/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
	}

	if body != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	resp, err := c.Client.Do(req)
	defer func() {
		if time.Until(c.next[source]) < 500*time.Millisecond {
			c.next[source] = time.Now().Add(500 * time.Millisecond)
		}
	}()
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 429 || resp.StatusCode == 503 {
		delay := time.Minute
		if seconds, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && seconds > 0 {
			delay = time.Duration(min(seconds, 86400)) * time.Second
		} else if date, err := http.ParseTime(resp.Header.Get("Retry-After")); err == nil && date.After(time.Now()) {
			delay = time.Until(date)
		}
		c.next[source] = time.Now().Add(delay + time.Second)
		return errLyricsBusy
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s HTTP %d", sourceName(source), resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, (4<<20)+1))
	if err != nil || len(raw) > 4<<20 {
		return errors.New("来源响应过大或读取失败")
	}
	if source == "kuwo" {
		raw = kuwoJSON(raw)
	}
	return json.Unmarshal(raw, out)
}

func (c *Catalog) retryAfter() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	delay := time.Second
	for _, next := range c.next {
		if time.Until(next) > delay {
			delay = time.Until(next)
		}
	}
	return int(delay.Seconds()) + 1
}

func joinNames(names []struct {
	Name string `json:"name"`
}) string {
	result := make([]string, 0, len(names))
	for _, n := range names {
		if n.Name != "" {
			result = append(result, n.Name)
		}
	}
	return strings.Join(result, " / ")
}

func (c *Catalog) Search(ctx context.Context, source, title, artist string) ([]MetadataCandidate, error) {
	items := []MetadataCandidate{}
	term := strings.TrimSpace(title + " " + artist)
	switch source {
	case "migu", "kuwo":
		found, err := c.searchChinese(ctx, source, term)
		if err != nil {
			return nil, err
		}
		items = found
	case "netease":
		var result struct {
			Code   int `json:"code"`
			Result struct {
				Songs []struct {
					ID      int64  `json:"id"`
					Name    string `json:"name"`
					Artists []struct {
						Name string `json:"name"`
					} `json:"artists"`
					Album struct {
						Name    string `json:"name"`
						Publish int64  `json:"publishTime"`
					} `json:"album"`
					Duration float64 `json:"duration"`
				} `json:"songs"`
			} `json:"result"`
		}
		if err := c.get(ctx, source, "https://music.163.com/api/search/get/web", nil,
			url.Values{"s": {term}, "type": {"1"}, "limit": {"10"}, "offset": {"0"}}, &result); err != nil {
			return nil, err
		}
		if result.Code != 200 {
			return nil, fmt.Errorf("网易云音乐 code %d", result.Code)
		}
		for _, song := range result.Result.Songs {
			m := TrackMetadata{Title: song.Name, Artist: joinNames(song.Artists), Album: song.Album.Name, Source: source}
			if song.Album.Publish > 0 {
				m.Year = time.UnixMilli(song.Album.Publish).UTC().Format("2006")
			}
			items = append(items, MetadataCandidate{TrackMetadata: m, Duration: song.Duration / 1000, SourceID: strconv.FormatInt(song.ID, 10)})
		}
	case "qq":
		payload, _ := json.Marshal(map[string]any{"req_1": map[string]any{
			"module": "music.search.SearchCgiService", "method": "DoSearchForQQMusicDesktop",
			"param": map[string]any{"query": term, "num_per_page": 10, "page_num": 1, "search_type": 0},
		}})
		var result struct {
			Code int `json:"code"`
			Req  struct {
				Code int `json:"code"`
				Data struct {
					Body struct {
						Song struct {
							List []struct {
								MID    string `json:"mid"`
								Name   string `json:"name"`
								Singer []struct {
									Name string `json:"name"`
								} `json:"singer"`
								Album struct {
									Name string `json:"name"`
								} `json:"album"`
								Interval float64 `json:"interval"`
								Date     string  `json:"time_public"`
								Number   int     `json:"index_album"`
							} `json:"list"`
						} `json:"song"`
					} `json:"body"`
				} `json:"data"`
			} `json:"req_1"`
		}
		if err := c.get(ctx, source, "https://u.y.qq.com/cgi-bin/musicu.fcg", url.Values{"data": {string(payload)}}, nil, &result); err != nil {
			return nil, err
		}
		if result.Code != 0 || result.Req.Code != 0 {
			return nil, errors.New("QQ音乐搜索失败")
		}
		for _, song := range result.Req.Data.Body.Song.List {
			m := TrackMetadata{Title: song.Name, Artist: joinNames(song.Singer), Album: song.Album.Name, Number: song.Number, Source: source}
			if len(song.Date) >= 4 {
				m.Year = song.Date[:4]
			}
			items = append(items, MetadataCandidate{TrackMetadata: m, Duration: song.Interval, SourceID: song.MID})
		}
	case "kugou":
		var result struct {
			Status int `json:"status"`
			Data   struct {
				Lists []struct {
					Title    string  `json:"SongName"`
					Artist   string  `json:"SingerName"`
					Album    string  `json:"AlbumName"`
					Hash     string  `json:"FileHash"`
					Duration float64 `json:"Duration"`
				} `json:"lists"`
			} `json:"data"`
		}
		if err := c.get(ctx, source, "https://songsearch.kugou.com/song_search_v2",
			url.Values{"keyword": {term}, "page": {"1"}, "pagesize": {"10"}, "platform": {"WebFilter"}, "filter": {"2"}, "iscorrection": {"1"}, "privilege_filter": {"0"}}, nil, &result); err != nil {
			return nil, err
		}
		if result.Status != 1 {
			return nil, errors.New("酷狗音乐搜索失败")
		}
		for _, song := range result.Data.Lists {
			m := TrackMetadata{Title: html.UnescapeString(song.Title), Artist: html.UnescapeString(song.Artist), Album: html.UnescapeString(song.Album), Source: source}
			items = append(items, MetadataCandidate{TrackMetadata: m, Duration: song.Duration, SourceID: song.Hash})
		}
	case "itunes":
		var result struct {
			Items []struct {
				ID          int64   `json:"trackId"`
				Title       string  `json:"trackName"`
				Artist      string  `json:"artistName"`
				AlbumArtist string  `json:"collectionArtistName"`
				Album       string  `json:"collectionName"`
				Date        string  `json:"releaseDate"`
				Genre       string  `json:"primaryGenreName"`
				Number      int     `json:"trackNumber"`
				Disc        int     `json:"discNumber"`
				Duration    float64 `json:"trackTimeMillis"`
			} `json:"results"`
		}
		if err := c.get(ctx, source, "https://itunes.apple.com/search",
			url.Values{"term": {term}, "entity": {"song"}, "limit": {"10"}, "country": {"US"}}, nil, &result); err != nil {
			return nil, err
		}
		for _, song := range result.Items {
			m := TrackMetadata{Title: song.Title, Artist: song.Artist, AlbumArtist: song.AlbumArtist, Album: song.Album, Genre: song.Genre, Number: song.Number, Disc: song.Disc, Source: source}
			if len(song.Date) >= 4 {
				m.Year = song.Date[:4]
			}
			items = append(items, MetadataCandidate{TrackMetadata: m, Duration: song.Duration / 1000, SourceID: strconv.FormatInt(song.ID, 10)})
		}
	default:
		return nil, errors.New("不支持的刮削源")
	}
	valid := items[:0]
	var failures []error
	for _, item := range items {
		if err := item.TrackMetadata.validate(); err != nil || item.SourceID == "" {
			continue
		}
		if err := c.hydrateCandidate(ctx, &item); err != nil {
			failures = append(failures, err)
			continue
		}
		valid = append(valid, item)
		if len(valid) == 10 {
			break
		}
	}
	if len(valid) == 0 && len(failures) > 0 {
		return nil, errors.Join(failures...)
	}
	return valid, nil
}

func (s *Scanner) searchCandidates(ctx context.Context, source, title, artist string) ([]MetadataCandidate, error) {
	if source == "auto" || source == "smart_tag" {
		return s.searchTrackCandidates(ctx, source, Track{Title: title, Artist: artist})
	}
	if source == "musicbrainz" {
		recordings, err := s.scraper.search(ctx, title, artist)
		return recordingCandidates(recordings), err
	}
	return s.catalog.Search(ctx, source, title, artist)
}

func (s *Scanner) searchTrackCandidates(ctx context.Context, source string, track Track) ([]MetadataCandidate, error) {
	if source != "auto" && source != "smart_tag" {
		items, err := s.searchCandidates(ctx, source, track.Title, track.Artist)
		rankCandidates(track, items)
		return items, err
	}
	items := []MetadataCandidate{}
	var failures []error
	attempts := 0
	for _, id := range s.store.SourceSettings().metadataOrder() {
		if source == "smart_tag" && id == "smart_tag" {
			continue
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		attempts++
		found, err := s.searchTrackCandidates(ctx, id, track)
		if err != nil {
			failures = append(failures, err)
			continue
		}
		if source == "auto" && len(found) > 0 && candidateMatches(track, found[0], 1) {
			return found, nil
		}
		items = append(items, found...)
	}
	if attempts == 0 {
		return nil, errors.New("没有可用的刮削源，请在设置中启用来源")
	}
	if len(failures) == attempts {
		return nil, errors.Join(failures...)
	}
	if source == "smart_tag" {
		for i := range items {
			item := &items[i]
			score := 0
			if normalize(item.Title) == normalize(track.Title) {
				score += 45
			}
			if normalize(item.Artist) == normalize(track.Artist) {
				score += 35
			}
			if track.Album != "" && normalize(item.Album) == normalize(track.Album) {
				score += 10
			}
			if item.Duration > 0 && abs(item.Duration-track.Duration) <= 5 {
				score += 10
			}
			if item.Source == "musicbrainz" && item.Score < 95 {
				score = 0
			}
			item.Score = score
		}
		sort.SliceStable(items, func(i, j int) bool { return items[i].Score > items[j].Score })
		if len(items) > 20 {
			items = items[:20]
		}
	}
	rankCandidates(track, items)
	return items, nil
}

// Keep identity and album checks ahead of duration so a different song never wins on length.
func rankCandidates(t Track, items []MetadataCandidate) {
	sort.SliceStable(items, func(i, j int) bool {
		a, b := items[i], items[j]
		am, bm := candidateIdentityMatches(t, a), candidateIdentityMatches(t, b)
		if am != bm {
			return am
		}
		if t.Duration > 0 {
			if (a.Duration > 0) != (b.Duration > 0) {
				return a.Duration > 0
			}
			if a.Duration > 0 && abs(a.Duration-t.Duration) != abs(b.Duration-t.Duration) {
				return abs(a.Duration-t.Duration) < abs(b.Duration-t.Duration)
			}
		}
		return a.Score > b.Score
	})
}

func candidateIdentityMatches(t Track, c MetadataCandidate) bool {
	return normalize(t.Title) != "" && normalize(t.Artist) != "" && normalize(t.Title) == normalize(c.Title) && normalize(t.Artist) == normalize(c.Artist) && (t.Album == "" || t.Album == "Unknown Album" || normalize(t.Album) == normalize(c.Album))
}

func candidateMatches(t Track, c MetadataCandidate, tolerance float64) bool {
	return candidateIdentityMatches(t, c) && t.Duration > 0 && c.Duration > 0 && abs(t.Duration-c.Duration) <= tolerance
}

func (s *Scanner) enrich(ctx context.Context, t *Track, source string) error {
	if t.Artist == "" {
		return errNoMetadata
	}
	if source == "musicbrainz" {
		return s.scraper.Enrich(ctx, t)
	}
	ids := []string{source}
	if source == "auto" {
		ids = s.store.SourceSettings().metadataOrder()
	}
	var failures []error
	var best *MetadataCandidate
	for _, id := range ids {
		if err := ctx.Err(); err != nil {
			return err
		}
		candidates, err := s.searchTrackCandidates(ctx, id, *t)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", sourceName(id), err))
			continue
		}
		for _, c := range candidates {
			if !candidateMatches(*t, c, 5) || (id == "musicbrainz" && c.Score < 95) || (id == "smart_tag" && c.Score < 80) {
				continue
			}
			if best == nil || abs(c.Duration-t.Duration) < abs(best.Duration-t.Duration) {
				copy := c
				best = &copy
			}
			break
		}
		// Rounded provider durations can differ by up to one second.
		if best != nil && (source != "auto" || abs(best.Duration-t.Duration) <= 1) {
			break
		}
		failures = append(failures, fmt.Errorf("%s: %w", sourceName(id), errNoMetadata))
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if best == nil {
		return errors.Join(append(failures, errNoMetadata)...)
	}
	c := *best
	if t.Album == "" {
		t.Album = c.Album
	}
	if t.AlbumArtist == "" {
		t.AlbumArtist = c.AlbumArtist
	}
	if t.Year == "" {
		t.Year = c.Year
	}
	if t.Genre == "" {
		t.Genre = c.Genre
	}
	if t.Number == 0 {
		t.Number = c.Number
	}
	if t.Disc == 0 {
		t.Disc = c.Disc
	}
	if t.MBID == "" {
		t.MBID = c.MBID
	}
	if t.ReleaseID == "" {
		t.ReleaseID = c.ReleaseID
	}
	t.MetadataSource = c.Source
	return nil
}

func (c *Catalog) FetchLyrics(ctx context.Context, source string, t Track) (*SavedLyrics, error) {
	candidates, err := c.Search(ctx, source, t.Title, t.Artist)
	if err != nil {
		return nil, err
	}
	rankCandidates(t, candidates)
	for _, song := range candidates {
		if !candidateMatches(t, song, 2) {
			continue
		}
		var text string
		switch source {
		case "netease":
			var result struct {
				Code int `json:"code"`
				LRC  struct {
					Lyric string `json:"lyric"`
				} `json:"lrc"`
			}
			err = c.get(ctx, source, "https://music.163.com/api/song/lyric",
				url.Values{"id": {song.SourceID}, "lv": {"-1"}, "kv": {"-1"}, "tv": {"-1"}}, nil, &result)
			if err == nil && result.Code != 200 {
				err = errors.New("网易云音乐歌词读取失败")
			}
			text = result.LRC.Lyric
		case "qq":
			var result struct {
				Code  int    `json:"code"`
				Lyric string `json:"lyric"`
			}
			err = c.get(ctx, source, "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
				url.Values{"songmid": {song.SourceID}, "format": {"json"}, "nobase64": {"1"}}, nil, &result)
			if err == nil && result.Code != 0 {
				err = errors.New("QQ音乐歌词读取失败")
			}
			text = html.UnescapeString(result.Lyric)
		case "kugou":
			var result struct {
				Status     int `json:"status"`
				Candidates []struct {
					ID       string  `json:"id"`
					Key      string  `json:"accesskey"`
					Title    string  `json:"song"`
					Artist   string  `json:"singer"`
					Duration float64 `json:"duration"`
				} `json:"candidates"`
			}
			err = c.get(ctx, source, "https://lyrics.kugou.com/search",
				url.Values{"ver": {"1"}, "man": {"yes"}, "client": {"pc"}, "hash": {song.SourceID}, "keyword": {t.Title + " " + t.Artist}, "duration": {strconv.Itoa(int(t.Duration * 1000))}}, nil, &result)
			if err != nil {
				return nil, err
			}
			if result.Status != 200 {
				return nil, errors.New("酷狗歌词搜索失败")
			}
			sort.SliceStable(result.Candidates, func(i, j int) bool {
				return abs(result.Candidates[i].Duration/1000-t.Duration) < abs(result.Candidates[j].Duration/1000-t.Duration)
			})
			for _, lyric := range result.Candidates {
				if normalize(lyric.Title) != normalize(t.Title) || normalize(lyric.Artist) != normalize(t.Artist) ||
					lyric.Duration <= 0 || abs(lyric.Duration/1000-t.Duration) > 2 {
					continue
				}
				var download struct {
					Status  int    `json:"status"`
					Content string `json:"content"`
				}
				err = c.get(ctx, source, "https://lyrics.kugou.com/download",
					url.Values{"ver": {"1"}, "client": {"pc"}, "id": {lyric.ID}, "accesskey": {lyric.Key}, "fmt": {"lrc"}, "charset": {"utf8"}}, nil, &download)
				if err != nil {
					return nil, err
				}
				if download.Status != 200 {
					return nil, errors.New("酷狗歌词读取失败")
				}
				raw, decodeErr := base64.StdEncoding.DecodeString(download.Content)
				if decodeErr != nil {
					return nil, decodeErr
				}
				text = string(raw)
				break
			}
		default:
			return nil, errors.New("不支持的歌词源")
		}
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(text) == "" {
			continue
		}
		return makeLyrics(text, source)
	}
	return nil, errNoLyrics
}
