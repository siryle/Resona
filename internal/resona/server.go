package resona

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	root "resona"
	"resona/internal/web"
)

type Server struct {
	config              Config
	store               *Store
	auth                *Auth
	scanner             *Scanner
	ctx                 context.Context
	logger              *slog.Logger
	logbook             *LogBook
	plugins             *Plugins
	cloud               *Cloud115
	scanScheduleChanged chan struct{}
	artistArtworkGate   chan struct{}
}

func NewServer(ctx context.Context, c Config) (*Server, error) {
	store, err := OpenStore(c.DataDir)
	if err != nil {
		return nil, err
	}
	ready := false
	defer func() {
		if !ready {
			store.Close()
		}
	}()
	auth, err := NewAuth(c)
	if err != nil {
		return nil, err
	}
	c.Username = auth.user
	book, err := openLogBook(c.DataDir)
	if err != nil {
		return nil, err
	}
	book.registerSecrets(store.pluginSettings())
	logger := slog.New(&logHandler{book: book, console: slog.Default().Handler()})
	s := &Server{config: c, store: store, auth: auth, scanner: NewScanner(c, store), ctx: ctx, logger: logger, logbook: book,
		scanScheduleChanged: make(chan struct{}, 1), artistArtworkGate: make(chan struct{}, 1)}
	s.scanner.logger = logger.With("category", "scan")
	if err := s.recoverFileOperation(); err != nil {
		return nil, err
	}
	logger.Info("Resona 已启动", "version", root.Version())
	s.plugins = newPlugins(s)
	s.cloud = newCloud115(s)
	if err := s.cloud.pruneMissingSTRMs(); err != nil {
		return nil, err
	}
	ready = true
	return s, nil
}

func (s *Server) Close() error { return s.store.Close() }

func (s *Server) Schedule() {
	s.plugins.Start()
	s.cloud.Schedule()
	go s.scheduleScans()
}

func (s *Server) Wait() { s.plugins.Wait(); s.scanner.Wait(); s.cloud.wg.Wait() }

func jsonResponse(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		slog.Debug("write response", "error", err)
	}
}

func apiError(w http.ResponseWriter, status int, msg string) {
	jsonResponse(w, status, map[string]string{"error": msg})
}

func decodeBody(w http.ResponseWriter, r *http.Request, body any) bool {
	if media, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); media != "application/json" {
		apiError(w, http.StatusUnsupportedMediaType, "Content-Type must be application/json")
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(body); err != nil {
		apiError(w, http.StatusBadRequest, "invalid JSON body")
		return false
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		apiError(w, http.StatusBadRequest, "expected one JSON object")
		return false
	}
	return true
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	s.cloud.routes(mux)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		jsonResponse(w, 200, map[string]any{"status": "ok", "version": root.Version()})
	})
	mux.HandleFunc("POST /api/v1/auth/login", s.login)
	mux.HandleFunc("GET /api/v1/auth/status", func(w http.ResponseWriter, r *http.Request) {
		jsonResponse(w, 200, map[string]any{"initialized": s.auth.initialized(), "username": s.config.Username})
	})
	mux.HandleFunc("POST /api/v1/auth/setup", s.setup)
	mux.HandleFunc("POST /api/v1/auth/logout", s.protect(s.logout))
	mux.HandleFunc("GET /api/v1/auth/session", s.protect(func(w http.ResponseWriter, r *http.Request) {
		jsonResponse(w, 200, map[string]string{"username": s.config.Username})
	}))
	mux.HandleFunc("GET /api/v1/system", s.protect(s.system))
	mux.HandleFunc("GET /api/v1/logs", s.protect(s.logs))
	mux.HandleFunc("GET /api/v1/files", s.protect(s.files))
	mux.HandleFunc("POST /api/v1/files/operations", s.protect(s.operateFiles))
	mux.HandleFunc("GET /api/v1/settings/scan", s.protect(s.getScanSchedule))
	mux.HandleFunc("PUT /api/v1/settings/scan", s.protect(s.setScanSchedule))
	mux.HandleFunc("GET /api/v1/cloud115/files", s.protect(s.cloud.files))
	mux.HandleFunc("POST /api/v1/cloud115/files/operations", s.protect(s.cloud.operateFiles))
	mux.HandleFunc("DELETE /api/v1/logs", s.protect(s.clearLogs))
	mux.HandleFunc("GET /api/v1/sources", s.protect(s.sources))
	mux.HandleFunc("PUT /api/v1/sources", s.protect(s.saveSources))
	mux.HandleFunc("GET /api/v1/plugins", s.protect(s.plugins.list))
	mux.HandleFunc("PUT /api/v1/plugins/{id}", s.protect(s.plugins.configure))
	mux.HandleFunc("POST /api/v1/plugins/{id}/{action}", s.protect(s.plugins.action))
	mux.HandleFunc("GET /api/v1/tracks", s.protect(s.tracks))
	mux.HandleFunc("GET /api/v1/tracks/{id}", s.protect(s.track))
	mux.HandleFunc("GET /api/v1/tracks/{id}/matches", s.protect(s.matches))
	mux.HandleFunc("PUT /api/v1/tracks/{id}/metadata", s.protect(s.correctMetadata))
	mux.HandleFunc("POST /api/v1/tracks/{id}/lyrics/scrape", s.protect(s.scrapeLyrics))
	mux.HandleFunc("POST /api/v1/tracks/{id}/lyrics/embed", s.protect(s.embedLyrics))
	mux.HandleFunc("PUT /api/v1/tracks/{id}/favorite", s.protect(s.favorite))
	mux.HandleFunc("GET /api/v1/tracks/{id}/stream", s.protect(s.stream))
	mux.HandleFunc("GET /api/v1/tracks/{id}/cover", s.protect(s.cover))
	mux.HandleFunc("GET /api/v1/tracks/{id}/lyrics", s.protect(s.lyrics))
	mux.HandleFunc("GET /api/v1/albums", s.protect(s.albums))
	mux.HandleFunc("GET /api/v1/artists", s.protect(s.artists))
	mux.HandleFunc("GET /api/v1/artists/avatar", s.protect(s.artistAvatar))
	mux.HandleFunc("GET /api/v1/jobs", s.protect(func(w http.ResponseWriter, r *http.Request) {
		jobs := s.store.Jobs(r.URL.Query().Get("summary") != "1")
		for i := range jobs {
			for k := range jobs[i].Items {
				item := &jobs[i].Items[k]
				if item.Duration <= 0 {
					if t, ok := s.store.Track(item.TrackID); ok {
						item.Duration = t.Duration
					}
				}
			}
		}
		jsonResponse(w, 200, map[string]any{"items": jobs})
	}))
	mux.HandleFunc("GET /api/v1/jobs/{id}", s.protect(func(w http.ResponseWriter, r *http.Request) {
		job, ok := s.store.Job(r.PathValue("id"))
		if !ok {
			apiError(w, 404, "任务记录已不存在")
			return
		}
		jsonResponse(w, 200, job)
	}))
	mux.HandleFunc("DELETE /api/v1/jobs", s.protect(s.deleteJobs))
	mux.HandleFunc("DELETE /api/v1/jobs/{id}", s.protect(func(w http.ResponseWriter, r *http.Request) {
		err := s.store.deleteJob(r.PathValue("id"))
		switch {
		case errors.Is(err, os.ErrNotExist):
			apiError(w, 404, "任务记录不存在")
		case errors.Is(err, errJobRunning):
			apiError(w, 409, err.Error())
		case err != nil:
			apiError(w, 500, "无法删除任务记录")
		default:
			s.scanner.logger.Info("任务记录已删除", "job", r.PathValue("id"))
			w.WriteHeader(http.StatusNoContent)
		}
	}))
	mux.HandleFunc("POST /api/v1/library/scan", s.protect(func(w http.ResponseWriter, r *http.Request) {
		var body struct{}
		if !decodeBody(w, r, &body) {
			return
		}
		j, err := s.scanner.StartLibrary(s.ctx)
		if err != nil {
			apiError(w, 409, err.Error())
			return
		}
		jsonResponse(w, 202, j)
	}))
	mux.HandleFunc("POST /api/v1/jobs/scan", s.protect(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Rescrape bool `json:"rescrape"`
		}
		if !decodeBody(w, r, &body) {
			return
		}
		j, err := s.scanner.Start(s.ctx, body.Rescrape)
		if err != nil {
			apiError(w, 409, err.Error())
			return
		}
		jsonResponse(w, 202, j)
	}))
	assets, _ := fs.Sub(web.Assets, "static")
	files := http.FileServer(http.FS(assets))
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			apiError(w, 404, "endpoint not found")
			return
		}
		if r.URL.Path != "/" && r.URL.Path != "/index.html" && r.URL.Path != "/app.js" &&
			r.URL.Path != "/style.css" && r.URL.Path != "/icon.png" && r.URL.Path != "/lyrics.js" &&
			r.URL.Path != "/playback.js" && r.URL.Path != "/plugins.js" && r.URL.Path != "/logs.js" && r.URL.Path != "/files.js" && r.URL.Path != "/cloud115.js" {
			http.NotFound(w, r)
			return
		}
		files.ServeHTTP(w, r)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "same-origin")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data: https://115.com https://*.115.com https://115cdn.com https://*.115cdn.com https://115cdn.net https://*.115cdn.net https://anxia.com https://*.anxia.com; style-src 'self'; script-src 'self'; "+cloudMediaCSP+"; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		if strings.HasPrefix(r.URL.Path, "/api/") {
			w.Header().Set("Cache-Control", "no-store")
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			if origin := r.Header.Get("Origin"); origin != "" {
				u, err := url.Parse(origin)
				if err != nil || u.Host != r.Host || (u.Scheme != "http" && u.Scheme != "https") {
					apiError(w, 403, "cross-origin request rejected")
					return
				}
			}
		}
		mux.ServeHTTP(w, r)
	})
}

func (s *Server) deleteJobs(w http.ResponseWriter, r *http.Request) {
	var body struct {
		IDs []string `json:"ids"`
		All bool     `json:"all"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	if body.All == (len(body.IDs) > 0) || len(body.IDs) > 30 {
		apiError(w, 400, "请选择任务记录，或明确指定全部删除")
		return
	}
	seen := map[string]bool{}
	for _, id := range body.IDs {
		if id == "" || seen[id] {
			apiError(w, 400, "任务 ID 不能为空或重复")
			return
		}
		seen[id] = true
	}
	deleted, running, err := s.store.deleteJobs(body.IDs, body.All)
	switch {
	case errors.Is(err, os.ErrNotExist):
		apiError(w, 404, "部分任务记录已不存在，请刷新后重试")
	case errors.Is(err, errJobRunning):
		apiError(w, 409, err.Error())
	case err != nil:
		apiError(w, 500, "无法删除任务记录")
	default:
		s.scanner.logger.Info("任务记录已删除", "count", deleted)
		jsonResponse(w, 200, map[string]int{"deleted": deleted, "skipped_running": running})
	}
}

func (s *Server) protect(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.auth.valid(r) {
			apiError(w, 401, "please sign in")
			return
		}
		next(w, r)
	}
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	if len(body.Username) > 128 || len(body.Password) > 1024 {
		apiError(w, 400, "credentials exceed maximum length")
		return
	}
	token, err := s.auth.login(r, body.Username, body.Password)
	if errors.Is(err, errSetupRequired) {
		apiError(w, 428, err.Error())
		return
	}
	if errors.Is(err, errThrottled) {
		w.Header().Set("Retry-After", "900")
		apiError(w, 429, "登录尝试过多，请稍后重试")
		return
	}
	if errors.Is(err, errCredentials) {
		apiError(w, 401, "用户名或密码不正确")
		return
	}
	if err != nil {
		s.logger.Error("persist login session", "error", err)
		apiError(w, 500, "无法保存登录状态，请检查数据目录权限")
		return
	}
	s.auth.cookie(w, r, token)
	jsonResponse(w, 200, map[string]any{"token": token, "username": s.config.Username, "expires_in": 604800})
}

func (s *Server) setup(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Password string `json:"password"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	err := s.auth.setup(body.Password)
	switch {
	case errors.Is(err, errAlreadyConfigured):
		apiError(w, 409, "管理员密码已设置，请使用已有密码登录")
	case errors.Is(err, errPasswordPolicy):
		apiError(w, 400, err.Error())
	case err != nil:
		s.logger.Error("initialize administrator", "error", err)
		apiError(w, 500, "无法保存管理员密码，请检查数据目录权限")
	default:
		s.logger.With("category", "settings").Info("管理员密码已初始化")
		jsonResponse(w, 201, map[string]bool{"initialized": true})
	}
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	if err := s.auth.logout(w, r); err != nil {
		s.logger.Error("persist session logout", "error", err)
		apiError(w, 500, "无法保存退出状态，请稍后重试")
		return
	}
	jsonResponse(w, 200, map[string]bool{"ok": true})
}

func (s *Server) system(w http.ResponseWriter, r *http.Request) {
	where, args := trackFilter(url.Values{"library": {r.URL.Query().Get("library")}})
	var count, artists, albums int
	var bytes int64
	var duration float64
	if err := s.store.db.QueryRowContext(r.Context(), "SELECT count(*),count(DISTINCT artist),count(DISTINCT album_id),coalesce(sum(size),0),coalesce(sum(duration),0) FROM tracks WHERE "+where, args...).Scan(&count, &artists, &albums, &bytes, &duration); err != nil {
		s.logger.Error("query library statistics", "error", err)
		apiError(w, 500, "无法读取音乐库统计")
		return
	}
	jsonResponse(w, 200, map[string]any{
		"version": root.Version(), "tracks": count, "albums": albums, "artists": artists,
		"bytes": bytes, "duration": duration, "scrape_enabled": s.config.Scrape,
		"scan_interval": s.scanSchedule().description(),
		"inbox_path":    s.config.InboxDir, "library_path": s.config.LibraryDir,
	})
}

func (s *Server) tracks(w http.ResponseWriter, r *http.Request) {
	out, total, offset, limit, err := s.store.queryTracks(r.Context(), r.URL.Query())
	if err != nil {
		s.logger.Error("query tracks", "error", err)
		apiError(w, 500, "无法读取音乐库")
		return
	}
	for i := range out {
		out[i] = s.trackWithLRC(out[i])
	}
	jsonResponse(w, 200, map[string]any{"items": out, "total": total, "offset": offset, "limit": limit})
}

func (s *Server) trackWithLRC(t Track) Track {
	// Only inspect sidecars on the requested page; never probe audio or contact 115.
	if local, ok := s.store.Track(t.ID); ok {
		_, err := s.scanner.localLyrics(local)
		t.HasLRCLyrics = err == nil
	}
	return t
}

func (s *Server) track(w http.ResponseWriter, r *http.Request) {
	t, ok := s.store.Track(r.PathValue("id"))
	if !ok {
		apiError(w, 404, "track not found")
		return
	}
	if r.URL.Query().Get("check_lyrics") == "true" && t.HasEmbeddedLyrics == nil {
		if _, err := s.scanner.cacheEmbeddedLyrics(r.Context(), t); err != nil && !errors.Is(err, os.ErrNotExist) {
			apiError(w, 500, "无法检测音频标签，请检查文件或重新扫描")
			return
		}
		t, _ = s.store.Track(t.ID)
	}
	jsonResponse(w, 200, s.trackWithLRC(t))
}

func (s *Server) favorite(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Favorite *bool `json:"favorite"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	if body.Favorite == nil {
		apiError(w, 400, "favorite is required")
		return
	}
	err := s.store.updateEntry(r.PathValue("id"), func(st *libraryState) error {
		t, ok := st.Tracks[r.PathValue("id")]
		if !ok {
			return os.ErrNotExist
		}
		t.Favorite = *body.Favorite
		st.Tracks[t.ID] = t
		return nil
	})
	if errors.Is(err, os.ErrNotExist) {
		apiError(w, 404, "track not found")
		return
	}
	if err != nil {
		s.logger.Error("save favorite", "error", err)
		apiError(w, 500, "unable to save favorite")
		return
	}
	s.track(w, r)
}

func (s *Server) stream(w http.ResponseWriter, r *http.Request) {
	s.store.mu.RLock()
	disk, ok := s.store.state.Tracks[r.PathValue("id")]
	t := publicTrack(disk)
	if !ok {
		s.store.mu.RUnlock()
		apiError(w, 404, "track not found")
		return
	}
	if disk.Remote != nil {
		s.store.mu.RUnlock()
		started := time.Now()
		refresh := r.URL.Query().Get("refresh") == "1"
		logger := s.logger.With("category", "playback", "track", disk.ID, "title", t.Title,
			"artist", t.Artist, "method", r.Method, "refresh", refresh)
		if disk.Unavailable {
			logger.Warn("115 302 播放不可用", "status", 503, "elapsed_ms", time.Since(started).Milliseconds(), "reason", "网盘歌曲暂不可用，请同步或重新探测")
			apiError(w, 503, "网盘歌曲暂不可用，请在 115 页面同步或重新探测")
			return
		}
		if refresh {
			s.cloud.invalidate(*disk.Remote, r.UserAgent())
		}
		link, err := s.cloud.downloadURL(r.Context(), *disk.Remote, r.UserAgent())
		if err != nil {
			logger.Warn("115 302 播放地址获取失败", "status", 502, "elapsed_ms", time.Since(started).Milliseconds(), "reason", err)
			apiError(w, 502, err.Error())
			return
		}
		w.Header().Set("Referrer-Policy", "no-referrer")
		http.Redirect(w, r, link, http.StatusFound)
		target, _ := url.Parse(link)
		logger.Info("115 302 播放跳转", "status", 302, "host", target.Hostname(), "elapsed_ms", time.Since(started).Milliseconds())
		return
	}
	path, err := filepath.EvalSymlinks(disk.File)
	if err != nil || !within(s.config.LibraryDir, path) {
		s.store.mu.RUnlock()
		apiError(w, 404, "audio file unavailable")
		return
	}
	f, err := os.Open(path)
	s.store.mu.RUnlock()
	if err != nil {
		apiError(w, 404, "audio file unavailable")
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		apiError(w, 404, "audio file unavailable")
		return
	}
	types := map[string]string{"mp3": "audio/mpeg", "flac": "audio/flac", "m4a": "audio/mp4", "alac": "audio/mp4",
		"aac": "audio/aac", "wav": "audio/wav", "ogg": "audio/ogg", "opus": "audio/ogg", "aif": "audio/aiff", "aiff": "audio/aiff", "wma": "audio/x-ms-wma"}
	w.Header().Set("Content-Type", types[t.Format])
	w.Header().Set("Content-Disposition", mime.FormatMediaType("inline", map[string]string{"filename": trackFileName(t)}))
	http.ServeContent(w, r, trackFileName(t), info.ModTime(), f)
}

func (s *Server) cover(w http.ResponseWriter, r *http.Request) {
	t, ok := s.store.Track(r.PathValue("id"))
	if !ok || t.Artwork == "" {
		http.NotFound(w, r)
		return
	}
	path := filepath.Join(s.config.DataDir, "artwork", t.ID+".jpg")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	http.ServeFile(w, r, path)
}

func (s *Server) lyrics(w http.ResponseWriter, r *http.Request) {
	t, ok := s.store.Track(r.PathValue("id"))
	if !ok {
		apiError(w, 404, "track not found")
		return
	}
	lyric, err := s.scanner.readLyrics(r.Context(), t)
	if err != nil {
		apiError(w, 404, "no lyrics available")
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Lyrics-Source", lyric.Source)
	io.WriteString(w, lyric.Text)
}

type Album struct {
	ID       string  `json:"id"`
	Title    string  `json:"title"`
	Artist   string  `json:"artist"`
	Year     string  `json:"year"`
	Artwork  string  `json:"artwork"`
	Tracks   int     `json:"tracks"`
	Duration float64 `json:"duration"`
}

func albumID(t Track) string {
	key := strings.ToLower(t.AlbumArtist + "\x00" + t.Album)
	if t.Library == "cloud" {
		key = "cloud\x00" + key
	}
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:12])
}

func (s *Server) albums(w http.ResponseWriter, r *http.Request) {
	out, err := s.store.queryAlbums(r.Context(), url.Values{"library": {r.URL.Query().Get("library")}})
	if err != nil {
		s.logger.Error("query albums", "error", err)
		apiError(w, 500, "无法读取专辑")
		return
	}
	jsonResponse(w, 200, map[string]any{"items": out})
}

func (s *Server) artists(w http.ResponseWriter, r *http.Request) {
	out, err := s.store.queryArtists(r.Context(), url.Values{"library": {r.URL.Query().Get("library")}})
	if err != nil {
		s.logger.Error("query artists", "error", err)
		apiError(w, 500, "无法读取艺术家")
		return
	}
	for i := range out {
		out[i].Artwork = artistArtworkURL(out[i].Name)
	}
	jsonResponse(w, 200, map[string]any{"items": out})
}
