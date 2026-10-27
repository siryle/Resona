package resona

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	root "resona"
)

type probeResult struct {
	Format struct {
		Duration string            `json:"duration"`
		Bitrate  string            `json:"bit_rate"`
		Tags     map[string]string `json:"tags"`
	} `json:"format"`
	Streams []struct {
		Type       string            `json:"codec_type"`
		SampleRate string            `json:"sample_rate"`
		Bitrate    string            `json:"bit_rate"`
		Tags       map[string]string `json:"tags"`
	} `json:"streams"`
}

var trackPrefix = regexp.MustCompile(`^\d{1,3}[\s._-]+`)

func readMetadata(ctx context.Context, path string) (Track, error) {
	return probeMetadata(ctx, path, path, "")
}

func probeMetadata(ctx context.Context, input, name, userAgent string) (Track, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	args := []string{"-v", "error"}
	if userAgent != "" {
		args = append(args, "-protocol_whitelist", "http,https,tls,tcp", "-rw_timeout", "10000000", "-user_agent", userAgent)
	}
	args = append(args, "-show_format", "-show_streams", "-of", "json", input)
	cmd := exec.CommandContext(ctx, "ffprobe", args...)
	out, err := cmd.Output()
	if err != nil {
		return Track{}, fmt.Errorf("ffprobe: %w", err)
	}
	var p probeResult
	if err := json.Unmarshal(out, &p); err != nil {
		return Track{}, err
	}
	tags := map[string]string{}
	for k, v := range p.Format.Tags {
		tags[strings.ToLower(k)] = strings.TrimSpace(v)
	}
	audio := false
	t := Track{Format: strings.TrimPrefix(strings.ToLower(filepath.Ext(name)), ".")}
	for _, stream := range p.Streams {
		if stream.Type == "audio" {
			audio = true
			for k, v := range stream.Tags {
				if tags[strings.ToLower(k)] == "" {
					tags[strings.ToLower(k)] = strings.TrimSpace(v)
				}
			}
			t.SampleRate, _ = strconv.Atoi(stream.SampleRate)
			t.Bitrate, _ = strconv.Atoi(stream.Bitrate)
			break
		}
	}
	if !audio {
		return Track{}, fmt.Errorf("file has no audio stream")
	}
	t.Duration, err = strconv.ParseFloat(p.Format.Duration, 64)
	if err != nil || t.Duration <= 0 || math.IsNaN(t.Duration) || math.IsInf(t.Duration, 0) {
		return Track{}, fmt.Errorf("audio has no valid duration")
	}
	if t.Bitrate == 0 {
		t.Bitrate, _ = strconv.Atoi(p.Format.Bitrate)
	}
	t.Title, t.Artist, t.Album = tags["title"], tags["artist"], tags["album"]
	t.AlbumArtist, t.Year, t.Genre = tags["album_artist"], tags["date"], tags["genre"]
	if t.AlbumArtist == "" {
		t.AlbumArtist = tags["albumartist"]
	}
	if t.Year == "" {
		t.Year = tags["year"]
	}
	if len(t.Year) > 4 {
		t.Year = t.Year[:4]
	}
	t.Number, _ = strconv.Atoi(strings.Split(tags["track"], "/")[0])
	t.Disc, _ = strconv.Atoi(strings.Split(tags["disc"], "/")[0])
	t.MBID = tags["musicbrainz_trackid"]
	t.TagLyrics = taggedLyrics(tags)
	title := trackPrefix.ReplaceAllString(strings.TrimSuffix(filepath.Base(name), filepath.Ext(name)), "")
	if parts := strings.SplitN(title, " - ", 2); len(parts) == 2 {
		if t.Artist == "" {
			t.Artist = strings.TrimSpace(parts[0])
		}
		title = strings.TrimSpace(parts[1])
	}
	if t.Title == "" {
		t.Title = title
	}
	return t, nil
}

func taggedLyrics(tags map[string]string) string {
	for _, key := range []string{"lyrics", "unsyncedlyrics", "unsynced lyrics", "syncedlyrics", "synced lyrics", "uslt", "sylt"} {
		if lyric, err := makeLyrics(tags[key], "embedded"); err == nil {
			return lyric.Text
		}
	}
	keys := []string{}
	for key := range tags {
		if strings.HasPrefix(key, "lyrics-") || strings.HasPrefix(key, "lyrics:") || strings.HasPrefix(key, "unsyncedlyrics-") {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	for _, key := range keys {
		if lyric, err := makeLyrics(tags[key], "embedded"); err == nil {
			return lyric.Text
		}
	}
	return ""
}

type recording struct {
	ID     string `json:"id"`
	Title  string `json:"title"`
	Score  int    `json:"score"`
	Length int    `json:"length"`
	Credit []struct {
		Name   string `json:"name"`
		Artist struct {
			Name string `json:"name"`
		} `json:"artist"`
	} `json:"artist-credit"`
	Releases []struct {
		ID     string `json:"id"`
		Title  string `json:"title"`
		Date   string `json:"date"`
		Status string `json:"status"`
		Group  struct {
			Type string `json:"primary-type"`
		} `json:"release-group"`
	} `json:"releases"`
}

type Scraper struct {
	Client   *http.Client
	Endpoint string
	last     time.Time
	mu       sync.Mutex
}

func normalize(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return -1
	}, s)
}

func exactRecording(t Track, r recording) bool {
	if r.Score < 95 || normalize(t.Title) != normalize(r.Title) || t.Artist == "" {
		return false
	}
	if r.Length <= 0 || t.Duration <= 0 || abs(t.Duration-float64(r.Length)/1000) > 5 {
		return false
	}
	for _, c := range r.Credit {
		if normalize(t.Artist) == normalize(c.Name) || normalize(t.Artist) == normalize(c.Artist.Name) {
			return true
		}
	}
	return false
}

func abs(v float64) float64 {
	if v < 0 {
		return -v
	}
	return v
}

func luceneQuote(s string) string {
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(s) + `"`
}

// Enrich fills missing tags only; ambiguous matches keep the original metadata.
func (s *Scraper) Enrich(ctx context.Context, t *Track) error {
	if t.Artist == "" || (t.Album != "" && t.Year != "" && t.MBID != "" && t.ReleaseID != "") {
		if t.MBID != "" {
			t.MetadataSource = "musicbrainz"
		}
		return nil
	}
	recordings, err := s.search(ctx, t.Title, t.Artist)
	if err != nil {
		return err
	}
	sort.SliceStable(recordings, func(i, j int) bool {
		a, b := recordings[i], recordings[j]
		am, bm := exactRecording(*t, a), exactRecording(*t, b)
		if am != bm {
			return am
		}
		return abs(float64(a.Length)/1000-t.Duration) < abs(float64(b.Length)/1000-t.Duration)
	})
	for _, r := range recordings {
		if !exactRecording(*t, r) {
			continue
		}
		t.MetadataSource = "musicbrainz"
		if t.MBID == "" {
			t.MBID = r.ID
		}
		for _, release := range r.Releases {
			if release.Status != "Official" || (t.Album != "" && normalize(t.Album) != normalize(release.Title)) {
				continue
			}
			if t.Album == "" {
				t.Album = release.Title
			}
			t.ReleaseID = release.ID
			if t.Year == "" && len(release.Date) >= 4 {
				t.Year = release.Date[:4]
			}
			return nil
		}
		return nil
	}
	return errNoMetadata
}

func (s *Scraper) search(ctx context.Context, title, artist string) ([]recording, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delay := time.Until(s.last.Add(1100 * time.Millisecond))
	if delay > 0 {
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
	s.last = time.Now()
	query := `recording:` + luceneQuote(title)
	if artist != "" {
		query += ` AND artist:` + luceneQuote(artist)
	}
	endpoint := s.Endpoint
	if endpoint == "" {
		endpoint = "https://musicbrainz.org/ws/2/recording/"
	}
	u := endpoint + "?" + url.Values{"query": {query}, "fmt": {"json"}, "limit": {"10"}}.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Resona/"+root.Version().Version+" (self-hosted music library)")
	req.Header.Set("Accept", "application/json")
	resp, err := s.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("MusicBrainz HTTP %d", resp.StatusCode)
	}
	var body struct {
		Recordings []recording `json:"recordings"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&body); err != nil {
		return nil, err
	}
	return body.Recordings, nil
}
