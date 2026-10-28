package resona

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func artistArtworkURL(name string) string {
	if strings.TrimSpace(name) == "" || strings.EqualFold(strings.TrimSpace(name), "Unknown Artist") {
		return ""
	}
	return "/api/v1/artists/avatar?name=" + url.QueryEscape(name)
}

func (c *Catalog) artistArtwork(ctx context.Context, source, name string) (string, error) {
	switch source {
	case "qq":
		query, _ := json.Marshal(name)
		payload := fmt.Sprintf(`{"req_1":{"module":"music.search.SearchCgiService","method":"DoSearchForQQMusicDesktop","param":{"query":%s,"num_per_page":10,"page_num":1,"search_type":1}}}`, query)
		var result struct {
			Code int `json:"code"`
			Req  struct {
				Code int `json:"code"`
				Data struct {
					Body struct {
						Singer struct {
							List []struct {
								Name string `json:"singerName"`
								Pic  string `json:"singerPic"`
							} `json:"list"`
						} `json:"singer"`
					} `json:"body"`
				} `json:"data"`
			} `json:"req_1"`
		}
		if err := c.get(ctx, source, "https://u.y.qq.com/cgi-bin/musicu.fcg", url.Values{"data": {payload}}, nil, &result); err != nil {
			return "", err
		}
		if result.Code != 0 || result.Req.Code != 0 {
			return "", errors.New("QQ Music artist search failed")
		}
		for _, artist := range result.Req.Data.Body.Singer.List {
			if strings.EqualFold(strings.TrimSpace(artist.Name), strings.TrimSpace(name)) && artist.Pic != "" {
				return artist.Pic, nil
			}
		}
	case "netease":
		var result struct {
			Code   int `json:"code"`
			Result struct {
				Artists []struct {
					Name   string `json:"name"`
					Pic    string `json:"picUrl"`
					Avatar string `json:"img1v1Url"`
				} `json:"artists"`
			} `json:"result"`
		}
		if err := c.get(ctx, source, "https://music.163.com/api/search/get/web", nil,
			url.Values{"s": {name}, "type": {"100"}, "limit": {"10"}, "offset": {"0"}}, &result); err != nil {
			return "", err
		}
		if result.Code != 200 {
			return "", fmt.Errorf("NetEase artist search code %d", result.Code)
		}
		for _, artist := range result.Result.Artists {
			if strings.EqualFold(strings.TrimSpace(artist.Name), strings.TrimSpace(name)) {
				if artist.Avatar != "" {
					return artist.Avatar, nil
				}
				if artist.Pic != "" {
					return artist.Pic, nil
				}
			}
		}
	}
	return "", errNoMetadata
}

func validArtistImageURL(u *url.URL, source string) bool {
	if u.User != nil || u.Port() != "" || (u.Scheme != "https" && u.Scheme != "http") {
		return false
	}
	host := strings.ToLower(u.Hostname())
	return (source == "qq" && host == "y.gtimg.cn") ||
		(source == "netease" && strings.HasSuffix(host, ".music.126.net"))
}

func (c *Catalog) downloadArtistArtwork(ctx context.Context, source, rawURL, path string) error {
	u, err := url.Parse(rawURL)
	if err != nil || !validArtistImageURL(u, source) {
		return errors.New("invalid artist image URL")
	}
	u.Scheme = "https"
	if source == "netease" {
		query := u.Query()
		query.Set("param", "500y500")
		u.RawQuery = query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Resona")
	if source == "qq" {
		req.Header.Set("Referer", "https://y.qq.com/")
	} else {
		req.Header.Set("Referer", "https://music.163.com/")
	}
	client := *c.Client
	client.CheckRedirect = func(next *http.Request, via []*http.Request) error {
		if len(via) >= 10 || next.URL.Scheme != "https" || !validArtistImageURL(next.URL, source) {
			return errors.New("invalid artist image redirect")
		}
		if c.Client.CheckRedirect != nil {
			return c.Client.CheckRedirect(next, via)
		}
		return nil
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("artist image HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, (5<<20)+1))
	if err != nil {
		return err
	}
	if len(data) > 5<<20 {
		return errors.New("artist image exceeds size limit")
	}
	return cacheArtwork(path, data)
}

func (s *Server) artistAvatar(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	if artistArtworkURL(name) == "" {
		http.NotFound(w, r)
		return
	}
	var exists bool
	if err := s.store.db.QueryRowContext(r.Context(),
		"SELECT EXISTS(SELECT 1 FROM tracks WHERE visible=1 AND artist=?)", name).Scan(&exists); err != nil {
		apiError(w, 500, "无法读取艺术家")
		return
	}
	if !exists {
		http.NotFound(w, r)
		return
	}
	path := filepath.Join(s.config.DataDir, "artwork", "artists", fmt.Sprintf("%x.jpg", sha256.Sum256([]byte(name))))
	serveCached := func() bool {
		if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() {
			w.Header().Set("Cache-Control", "private, max-age=86400")
			http.ServeFile(w, r, path)
			return true
		}
		if info, err := os.Stat(path + ".missing"); err == nil && time.Since(info.ModTime()) < 6*time.Hour {
			http.NotFound(w, r)
			return true
		}
		return false
	}
	if serveCached() {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	select {
	case s.artistArtworkGate <- struct{}{}:
		defer func() { <-s.artistArtworkGate }()
	case <-ctx.Done():
		apiError(w, 504, "获取艺术家头像超时")
		return
	}
	if serveCached() {
		return
	}
	var failures []error
	attempts := 0
	for _, source := range s.store.SourceSettings().metadataOrder() {
		if source != "qq" && source != "netease" {
			continue
		}
		attempts++
		imageURL, err := s.scanner.catalog.artistArtwork(ctx, source, name)
		if errors.Is(err, errNoMetadata) {
			continue
		}
		if err == nil {
			err = s.scanner.catalog.downloadArtistArtwork(ctx, source, imageURL, path)
		}
		if err != nil {
			failures = append(failures, err)
			continue
		}
		os.Remove(path + ".missing")
		serveCached()
		return
	}
	if len(failures) > 0 {
		s.logger.Debug("artist artwork unavailable", "artist", name, "error", errors.Join(failures...))
		w.Header().Set("Retry-After", "60")
		apiError(w, 502, "艺术家头像来源暂不可用")
		return
	}
	if attempts > 0 {
		if err := os.MkdirAll(filepath.Dir(path), 0750); err == nil {
			if err := os.WriteFile(path+".missing", nil, 0600); err != nil {
				s.logger.Debug("cache missing artist artwork", "error", err)
			}
		}
	}
	http.NotFound(w, r)
}
