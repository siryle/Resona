package resona

import (
	"errors"
	"net/http"
	"os"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

type TrackMetadata struct {
	Title       string `json:"title"`
	Artist      string `json:"artist"`
	AlbumArtist string `json:"album_artist"`
	Album       string `json:"album"`
	Year        string `json:"year"`
	Genre       string `json:"genre"`
	Number      int    `json:"number"`
	Disc        int    `json:"disc"`
	MBID        string `json:"mbid"`
	ReleaseID   string `json:"release_id"`
	Source      string `json:"source,omitempty"`
}

func metadataOf(t Track) TrackMetadata {
	return TrackMetadata{t.Title, t.Artist, t.AlbumArtist, t.Album, t.Year, t.Genre, t.Number, t.Disc, t.MBID, t.ReleaseID, t.MetadataSource}
}

func (m TrackMetadata) apply(t *Track) {
	t.Title, t.Artist, t.AlbumArtist, t.Album = m.Title, m.Artist, m.AlbumArtist, m.Album
	t.Year, t.Genre, t.Number, t.Disc = m.Year, m.Genre, m.Number, m.Disc
	t.MBID, t.ReleaseID = m.MBID, m.ReleaseID
	t.MetadataSource = m.Source
}

func (m *TrackMetadata) validate() error {
	for _, field := range []*string{&m.Title, &m.Artist, &m.AlbumArtist, &m.Album, &m.Year, &m.Genre, &m.MBID, &m.ReleaseID} {
		*field = strings.TrimSpace(*field)
		if !utf8.ValidString(*field) || len(*field) > 1024 || strings.ContainsFunc(*field, unicode.IsControl) {
			return errors.New("标签不能包含控制字符，且每项最多 1024 字节")
		}
	}
	if m.Title == "" || m.Artist == "" {
		return errors.New("歌曲名称和艺术家不能为空")
	}
	if m.AlbumArtist == "" {
		m.AlbumArtist = m.Artist
	}
	if m.Year != "" {
		year, err := strconv.Atoi(m.Year)
		if err != nil || len(m.Year) != 4 || year < 1000 || year > 9999 {
			return errors.New("年份须为四位数字，或留空")
		}
	}
	if m.Number < 0 || m.Number > 9999 || m.Disc < 0 || m.Disc > 9999 {
		return errors.New("曲序和碟号须在 0 到 9999 之间")
	}
	for _, id := range []string{m.MBID, m.ReleaseID} {
		if id != "" && !mbIDPattern.MatchString(id) {
			return errors.New("MusicBrainz ID 格式不正确")
		}
	}
	if m.Source != "" && m.Source != "manual" && !validSource(m.Source, false) {
		return errors.New("不支持的刮削源")
	}
	return nil
}

func (s *Server) correctMetadata(w http.ResponseWriter, r *http.Request) {
	var body TrackMetadata
	if !decodeBody(w, r, &body) {
		return
	}
	if err := body.validate(); err != nil {
		apiError(w, 400, err.Error())
		return
	}
	if body.Source == "" {
		body.Source = "manual"
	}
	s.cloud.mu.Lock()
	defer s.cloud.mu.Unlock()
	s.scanner.mu.Lock()
	if s.scanner.active || s.scanner.editing || s.cloud.busyLocked() {
		s.scanner.mu.Unlock()
		apiError(w, 409, errLibraryBusy.Error())
		return
	}
	s.scanner.editing = true
	s.scanner.mu.Unlock()
	defer func() {
		s.scanner.mu.Lock()
		s.scanner.editing = false
		s.scanner.mu.Unlock()
	}()
	current, ok := s.store.Track(r.PathValue("id"))
	if !ok {
		apiError(w, 404, "track not found")
		return
	}
	corrected := current
	body.apply(&corrected)
	if _, ok := s.store.duplicateTrack(corrected); ok {
		apiError(w, 409, "同一音乐库已有同名同歌手歌曲，已跳过整理")
		return
	}
	move, err := s.scanner.stageTrackMove(r.Context(), current.Path, corrected)
	if err != nil {
		s.scanner.logger.Error("organize corrected metadata", "error", err)
		apiError(w, 500, "无法移动到更正后的目录，原文件和标签已保留")
		return
	}
	err = s.store.update(func(st *libraryState) error {
		t, ok := st.Tracks[r.PathValue("id")]
		if !ok {
			return os.ErrNotExist
		}
		before := lyricsIdentity(t.Track)
		body.apply(&t.Track)
		t.File = move.destination
		t.MetadataLocked = true
		if before != lyricsIdentity(t.Track) {
			t.Lyrics = nil
		}
		st.Tracks[t.ID] = t
		return nil
	})
	if err != nil {
		move.rollback()
	}
	if err != nil {
		s.scanner.logger.Error("save corrected metadata", "error", err)
		apiError(w, 500, "无法保存更正信息")
		return
	}
	if err := move.finish(); err != nil {
		s.scanner.logger.Warn("remove old corrected track path", "error", err)
	}
	s.track(w, r)
}

func (s *Server) matches(w http.ResponseWriter, r *http.Request) {
	t, ok := s.store.Track(r.PathValue("id"))
	if !ok {
		apiError(w, 404, "track not found")
		return
	}
	title, artist := t.Title, t.Artist
	if r.URL.Query().Has("title") {
		title = strings.TrimSpace(r.URL.Query().Get("title"))
	}
	if r.URL.Query().Has("artist") {
		artist = strings.TrimSpace(r.URL.Query().Get("artist"))
	}
	if title == "" || len(title) > 1024 || len(artist) > 1024 {
		apiError(w, 400, "请输入歌曲名称，搜索字段最多 1024 字节")
		return
	}
	source := r.URL.Query().Get("source")
	if source == "" {
		source = s.store.SourceSettings().Metadata
	}
	if !validSource(source, false) {
		apiError(w, 400, "不支持的刮削源")
		return
	}
	t.Title, t.Artist = title, artist
	items, err := s.scanner.searchTrackCandidates(r.Context(), source, t)
	if err != nil {
		s.scanner.logger.Info("search metadata", "error", err)
		apiError(w, 502, "刮削源暂时不可用，请切换来源或直接编辑标签")
		return
	}
	jsonResponse(w, 200, map[string]any{"source": sourceName(source), "items": items})
}

func recordingCandidates(recordings []recording) []MetadataCandidate {
	items := []MetadataCandidate{}
	for _, rec := range recordings {
		names := []string{}
		for _, credit := range rec.Credit {
			name := credit.Name
			if name == "" {
				name = credit.Artist.Name
			}
			if name != "" {
				names = append(names, name)
			}
		}
		m := TrackMetadata{Title: rec.Title, Artist: strings.Join(names, " / "), MBID: rec.ID, Source: "musicbrainz"}
		m.AlbumArtist = m.Artist
		added := false
		for _, rel := range rec.Releases {
			if rel.Status != "Official" {
				continue
			}
			m.Album, m.ReleaseID, m.Year = rel.Title, rel.ID, ""
			if len(rel.Date) >= 4 {
				m.Year = rel.Date[:4]
			}
			items = append(items, MetadataCandidate{TrackMetadata: m, Duration: float64(rec.Length) / 1000, Score: rec.Score})
			added = true
			if len(items) >= 20 {
				break
			}
		}
		if !added {
			items = append(items, MetadataCandidate{TrackMetadata: m, Duration: float64(rec.Length) / 1000, Score: rec.Score})
		}
		if len(items) >= 20 {
			break
		}
	}
	return items
}
