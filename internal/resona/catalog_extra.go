package resona

import (
	"context"
	"encoding/json"
	"errors"
	"html"
	"net/url"
	"strconv"
	"strings"
)

func durationSeconds(raw json.RawMessage) float64 {
	value := strings.Trim(string(raw), `"`)
	var total float64
	for _, part := range strings.Split(value, ":") {
		seconds, err := strconv.ParseFloat(part, 64)
		if err != nil {
			return 0
		}
		total = total*60 + seconds
	}
	return total
}

// Kuwo's legacy search endpoint returns quoted JavaScript strings instead of JSON.
func kuwoJSON(raw []byte) []byte {
	if json.Valid(raw) {
		return raw
	}
	out := make([]byte, 0, len(raw))
	for i := 0; i < len(raw); i++ {
		if raw[i] != '\'' {
			out = append(out, raw[i])
			continue
		}
		out = append(out, '"')
		for i++; i < len(raw); i++ {
			ch := raw[i]
			if ch == '\'' {
				break
			}
			if ch == '\\' && i+1 < len(raw) {
				i++
				if raw[i] == '\'' {
					out = append(out, '\'')
				} else {
					out = append(out, '\\', raw[i])
				}
			} else {
				if ch == '"' {
					out = append(out, '\\')
				}
				out = append(out, ch)
			}
		}
		out = append(out, '"')
	}
	return out
}

func (c *Catalog) searchChinese(ctx context.Context, source, term string) ([]MetadataCandidate, error) {
	items := []MetadataCandidate{}
	if source == "migu" {
		var result struct {
			Code  string `json:"code"`
			Songs struct {
				Items []struct {
					ID      string `json:"copyrightId"`
					Title   string `json:"name"`
					Singers []struct {
						Name string `json:"name"`
					} `json:"singers"`
					Albums []struct {
						Name string `json:"name"`
					} `json:"albums"`
				} `json:"result"`
			} `json:"songResultData"`
		}
		if err := c.get(ctx, source, "https://c.musicapp.migu.cn/v1.0/content/search_all.do",
			url.Values{"text": {term}, "pageNo": {"1"}, "pageSize": {"10"}, "searchSwitch": {`{"song":1}`}}, nil, &result); err != nil {
			return nil, err
		}
		if result.Code != "000000" {
			return nil, errors.New("咪咕音乐搜索失败")
		}
		for _, song := range result.Songs.Items {
			m := TrackMetadata{Title: song.Title, Artist: joinNames(song.Singers), Source: source}
			if len(song.Albums) > 0 {
				m.Album = song.Albums[0].Name
			}
			items = append(items, MetadataCandidate{TrackMetadata: m, SourceID: song.ID})
		}
		return items, nil
	}
	var result struct {
		Items []struct {
			ID       string          `json:"MUSICRID"`
			Title    string          `json:"NAME"`
			Artist   string          `json:"ARTIST"`
			Album    string          `json:"ALBUM"`
			Duration json.RawMessage `json:"DURATION"`
		} `json:"abslist"`
	}
	if err := c.get(ctx, source, "https://search.kuwo.cn/r.s",
		url.Values{"all": {term}, "ft": {"music"}, "client": {"kt"}, "cluster": {"0"}, "pn": {"0"}, "rn": {"10"}, "rformat": {"json"}, "encoding": {"utf8"}}, nil, &result); err != nil {
		return nil, err
	}
	if result.Items == nil {
		return nil, errors.New("酷我音乐未返回搜索结果")
	}
	for _, song := range result.Items {
		items = append(items, MetadataCandidate{TrackMetadata: TrackMetadata{Title: html.UnescapeString(song.Title), Artist: html.UnescapeString(song.Artist), Album: html.UnescapeString(song.Album), Source: source}, SourceID: strings.TrimPrefix(song.ID, "MUSIC_"), Duration: durationSeconds(song.Duration)})
	}
	return items, nil
}

func (c *Catalog) hydrateCandidate(ctx context.Context, candidate *MetadataCandidate) error {
	if candidate.Source != "migu" || candidate.Duration > 0 {
		return nil
	}
	var result struct {
		Code  string `json:"code"`
		Items []struct {
			Length json.RawMessage `json:"length"`
			Track  string          `json:"trackNumber"`
			Disc   string          `json:"disc"`
		} `json:"resource"`
	}
	if err := c.get(ctx, "migu", "https://c.musicapp.migu.cn/v1.0/content/resourceinfo.do", url.Values{"copyrightId": {candidate.SourceID}, "resourceType": {"2"}}, nil, &result); err != nil {
		return err
	}
	if result.Code != "000000" || len(result.Items) == 0 {
		return errNoMetadata
	}
	item := result.Items[0]
	candidate.Duration = durationSeconds(item.Length)
	candidate.Number, _ = strconv.Atoi(item.Track)
	candidate.Disc, _ = strconv.Atoi(strings.TrimPrefix(item.Disc, "Disc "))
	return nil
}
