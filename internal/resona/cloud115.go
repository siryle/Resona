package resona

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

const probeUserAgent = "Resona/115Probe"

var cloudDownloadDomains = [...]string{"115.com", "115cdn.com", "115cdn.net", "anxia.com"}

var cloudMediaCSP = func() string {
	sources := []string{"'self'"}
	for _, domain := range cloudDownloadDomains {
		for _, scheme := range []string{"https", "http"} {
			sources = append(sources, scheme+"://"+domain, scheme+"://*."+domain)
		}
	}
	return "media-src " + strings.Join(sources, " ")
}()

type RemoteFile struct {
	Account  string `json:"account"`
	FileID   string `json:"file_id"`
	PickCode string `json:"pickcode"`
	SHA1     string `json:"sha1"`
	Size     int64  `json:"size"`
}

type CloudItem struct {
	RemoteFile
	Name        string      `json:"name"`
	Path        string      `json:"path"`
	State       string      `json:"state"`
	Error       string      `json:"error,omitempty"`
	TrackID     string      `json:"track_id"`
	Fingerprint string      `json:"fingerprint"`
	Queued      bool        `json:"queued,omitempty"`
	UpdatedAt   time.Time   `json:"updated_at"`
	Cover       *RemoteFile `json:"cover,omitempty"`
	LRC         *RemoteFile `json:"lrc,omitempty"`
}

type CloudSettings struct {
	RootID          string        `json:"root_id"`
	RootPath        string        `json:"root_path,omitempty"`
	BaseURL         string        `json:"base_url"`
	Enabled         bool          `json:"enabled"`
	IntervalMinutes int           `json:"interval_minutes"`
	SyncSchedule    *ScanSchedule `json:"sync_schedule,omitempty"`
	DownloadLyrics  bool          `json:"download_lyrics"`
	DownloadHTTP    bool          `json:"download_http"`
}

type CloudState struct {
	Settings    CloudSettings        `json:"settings"`
	Account     string               `json:"account"`
	AccountName string               `json:"account_name"`
	Cookie      string               `json:"cookie,omitempty"`
	LastSync    time.Time            `json:"last_sync"`
	Items       map[string]CloudItem `json:"items"`
	ProbePaused bool                 `json:"probe_paused,omitempty"`
	ProbeQueue  []string             `json:"probe_queue,omitempty"`
}

type cloudAuth struct {
	UID, Sign, Time string
	ClientType      string
	URL             string
	Expires         time.Time
}

type cloudLink struct {
	URL     string
	Expires time.Time
}

type Cloud115 struct {
	server                         *Server
	client                         *http.Client
	apiURL, webURL, userURL, qrURL string
	apiGate                        chan struct{}
	nextRequest                    time.Time
	mu                             sync.Mutex
	linkGate                       chan struct{}
	dataMu                         sync.Mutex
	syncCancel                     context.CancelFunc
	probeCancel                    context.CancelFunc
	syncStopping                   bool
	probeStopping                  bool
	syncDone                       int
	syncTotal                      int
	syncUnchanged                  int
	busy                           bool
	probeBusy                      bool
	fileBusy                       bool
	probeCurrent                   string
	probeMessage                   string
	message                        string
	auth                           cloudAuth
	links                          map[string]cloudLink
	downloadPath                   string
	scheduleChanged                chan struct{}
	wg                             sync.WaitGroup
	probe                          func(context.Context, CloudItem) (Track, error)
}

func newCloud115(s *Server) *Cloud115 {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	// QR status requests can wait about 30 seconds before reporting no change.
	c := &Cloud115{server: s, client: &http.Client{Transport: transport, Timeout: 45 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
		apiURL: "https://proapi.115.com", webURL: "https://webapi.115.com", userURL: "https://my.115.com",
		qrURL: "https://qrcodeapi.115.com", apiGate: make(chan struct{}, 1), linkGate: make(chan struct{}, 1), links: map[string]cloudLink{},
		scheduleChanged: make(chan struct{}, 1)}
	c.probe = c.probeFile
	return c
}

func validHex(value string, length int) bool {
	_, err := hex.DecodeString(value)
	return len(value) == length && err == nil
}

func cloudTrackID(account, fileID string) string {
	sum := sha256.Sum256([]byte("115\x00" + account + "\x00" + fileID))
	return hex.EncodeToString(sum[:])
}

// 115 mixes JSON strings and numbers for identifiers and sizes.
type cloudNumber string

func (n *cloudNumber) UnmarshalJSON(b []byte) error {
	if len(b) > 0 && b[0] == '"' {
		return json.Unmarshal(b, (*string)(n))
	}
	var value json.Number
	if err := json.Unmarshal(b, &value); err != nil {
		return err
	}
	*n = cloudNumber(value.String())
	return nil
}

func (c *Cloud115) snapshot() CloudState {
	c.server.store.mu.RLock()
	defer c.server.store.mu.RUnlock()
	value := c.server.store.state.Cloud
	value.ProbeQueue = slices.Clone(value.ProbeQueue)
	value.Items = make(map[string]CloudItem, len(c.server.store.state.Cloud.Items))
	for id, item := range c.server.store.state.Cloud.Items {
		value.Items[id] = item
	}
	return value
}

func (c *Cloud115) probeState() CloudState {
	c.server.store.mu.RLock()
	defer c.server.store.mu.RUnlock()
	state := c.server.store.state.Cloud
	// Published queue slices are immutable; only copy the item the worker needs.
	state.Items = map[string]CloudItem{}
	if len(state.ProbeQueue) > 0 {
		id := state.ProbeQueue[0]
		if item, ok := c.server.store.state.Cloud.Items[id]; ok {
			state.Items[id] = item
		}
	}
	return state
}

func (c *Cloud115) raw(ctx context.Context, method, endpoint string, form url.Values, cookie, ua string, out any) error {
	var body io.Reader
	if method == http.MethodGet {
		if len(form) > 0 {
			endpoint += "?" + form.Encode()
		}
	} else {
		body = strings.NewReader(form.Encode())
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return errors.New("无法构建 115 请求")
	}
	if method != http.MethodGet {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if cookie != "" {
		req.Header.Set("Cookie", cookie)
	}
	// An empty client UA must stay empty for UA-bound CDN links.
	req.Header.Set("User-Agent", ua)
	resp, err := c.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return errors.New("无法连接 115，请稍后重试")
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 {
		return errCloudAuth
	}
	if resp.StatusCode != 200 {
		return &cloudHTTPError{Status: resp.StatusCode, Path: req.URL.Path, RetryAfter: resp.Header.Get("Retry-After")}
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, (8<<20)+1))
	if err != nil || len(data) > 8<<20 {
		return errors.New("115 响应过大或读取失败")
	}
	var envelope struct {
		State json.RawMessage `json:"state"`
		Code  cloudNumber     `json:"code"`
		Errno cloudNumber     `json:"errno"`
		Data  json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return errors.New("115 返回了无效数据")
	}
	if string(envelope.State) != "true" && string(envelope.State) != "1" {
		code := string(envelope.Code)
		if code == "" || code == "0" {
			code = string(envelope.Errno)
		}
		if code == "401" || code == "99" || code == "911" || code == "990001" || code == "40101017" || code == "40101032" {
			return errCloudAuth
		}
		return fmt.Errorf("115 请求失败（代码 %s），请检查授权或稍后重试", code)
	}
	if out != nil {
		// Listing pagination fields live outside data.
		if err := json.Unmarshal(data, out); err != nil {
			return errors.New("无法解析 115 响应")
		}
	}
	return nil
}

var errCloudAuth = errors.New("115 登录已失效或需要验证，请重新扫码登录")

func (c *Cloud115) request(ctx context.Context, method, path string, form url.Values, ua string, out any) error {
	return c.requestAt(ctx, c.apiURL, method, path, form, ua, out)
}

func (c *Cloud115) requestAt(ctx context.Context, base, method, path string, form url.Values, ua string, out any) error {
	select {
	case c.apiGate <- struct{}{}:
		defer func() { <-c.apiGate }()
	case <-ctx.Done():
		return ctx.Err()
	}
	c.server.store.mu.RLock()
	cookie := c.server.store.state.Cloud.Cookie
	c.server.store.mu.RUnlock()
	if cookie == "" {
		return errCloudAuth
	}
	var err error
	retries := 3
	requestPath, _, _ := strings.Cut(path, "?")
	downloadRequest := method == http.MethodPost && (requestPath == "/app/chrome/downurl" ||
		requestPath == "/android/2.0/ufile/download")
	if downloadRequest {
		retries = 1
	}
	for attempt := 0; ; attempt++ {
		if err := cloudWait(ctx, time.Until(c.nextRequest)); err != nil {
			return err
		}
		err = c.raw(ctx, method, base+path, form, cookie, ua, out)
		c.nextRequest = time.Now().Add(300 * time.Millisecond)
		var rejection *cloudHTTPError
		if !errors.As(err, &rejection) ||
			(rejection.Status != http.StatusMethodNotAllowed && rejection.Status != http.StatusTooManyRequests) {
			break
		}
		c.nextRequest = time.Now().Add(cloudRetryDelay(rejection.RetryAfter, attempt))
		// Download URL POSTs are reads; other POSTs must never be replayed.
		if (method != http.MethodGet && !downloadRequest) || attempt == retries {
			break
		}
	}
	if errors.Is(err, errCloudAuth) {
		if saveErr := c.server.store.updateCloud(func(st *libraryState) error {
			if st.Cloud.Cookie == cookie {
				st.Cloud.Cookie = ""
				for id, track := range st.Tracks {
					if track.Remote != nil {
						track.Unavailable = true
						st.Tracks[id] = track
					}
				}
			}
			return nil
		}); saveErr != nil {
			return errors.New("无法保存 115 登录失效状态")
		}
	}
	return err
}

type cloudFile struct {
	ID       cloudNumber `json:"fid"`
	ParentID cloudNumber `json:"pid"`
	Path     string      `json:"-"`
	Name     string      `json:"fn"`
	Category cloudNumber `json:"fc"`
	PickCode string      `json:"pc"`
	SHA1     string      `json:"sha1"`
	Size     cloudNumber `json:"fs"`
	Modified cloudNumber `json:"upt"`
}

func validCloudURL(value string) bool {
	u, err := url.Parse(value)
	if err != nil || u.User != nil || u.Fragment != "" || u.Opaque != "" || strings.HasSuffix(u.Host, ":") ||
		(u.Scheme != "https" && u.Scheme != "http") {
		return false
	}
	if port := u.Port(); port != "" && !((u.Scheme == "https" && port == "443") || (u.Scheme == "http" && port == "80")) {
		return false
	}
	host := strings.ToLower(u.Hostname())
	for _, domain := range cloudDownloadDomains {
		if host == domain || strings.HasSuffix(host, "."+domain) {
			return true
		}
	}
	return false
}

func (c *Cloud115) invalidate(file RemoteFile, ua string) {
	c.linkGate <- struct{}{}
	delete(c.links, file.Account+"\x00"+file.PickCode+"\x00"+ua)
	<-c.linkGate
}

func (c *Cloud115) downloadURL(ctx context.Context, file RemoteFile, ua string) (string, error) {
	key := file.Account + "\x00" + file.PickCode + "\x00" + ua
	select {
	case c.linkGate <- struct{}{}:
		defer func() { <-c.linkGate }()
	case <-ctx.Done():
		return "", ctx.Err()
	}
	settings := c.summary()
	if !settings.Settings.Enabled || settings.Account != file.Account || settings.Cookie == "" {
		return "", errors.New("115 音源已停用或账号已更换")
	}
	if cached, ok := c.links[key]; ok && time.Now().Before(cached.Expires) {
		return cached.URL, nil
	}
	paths := []string{"/android/2.0/ufile/download", "/app/chrome/downurl"}
	if c.downloadPath == paths[1] {
		slices.Reverse(paths)
	}
	var link string
	var err, previous error
	for _, path := range paths {
		link, err = c.fetchDownloadURL(ctx, file, ua, path)
		if err == nil {
			c.downloadPath = path
			break
		}
		if previous != nil {
			if errors.Is(err, errCloudAuth) || ctx.Err() != nil {
				return "", err
			}
			cause := errors.Join(previous, err)
			if cloudRestricted(cause) {
				return "", &cloudDownloadError{cause: cause, http: settings.Settings.DownloadHTTP}
			}
			return "", cause
		}
		var rejection *cloudHTTPError
		if !errors.Is(err, errCloudCookieLink) && (!errors.As(err, &rejection) || rejection.Status != http.StatusMethodNotAllowed) {
			return "", err
		}
		previous = err
	}
	if err != nil {
		return "", err
	}
	u, _ := url.Parse(link)
	expires := time.Now().Add(5 * time.Minute)
	if stamp, err := strconv.ParseInt(u.Query().Get("t"), 10, 64); err == nil {
		exp := time.Unix(stamp, 0).Add(-time.Minute)
		if exp.Before(expires) {
			expires = exp
		}
	}
	if !expires.After(time.Now()) {
		return "", errors.New("115 下载地址已过期，请重试")
	}
	if len(c.links) >= 512 {
		clear(c.links)
	}
	c.links[key] = cloudLink{URL: link, Expires: expires}
	return link, nil
}

var errCloudCookieLink = errors.New("115 返回的地址需要额外 Cookie，无法安全用于 302 播放，请重新扫码登录")

func (c *Cloud115) fetchDownloadURL(ctx context.Context, file RemoteFile, ua, path string) (string, error) {
	var response struct {
		Data string `json:"data"`
	}
	field := "pickcode"
	if path != "/app/chrome/downurl" {
		field = "pick_code"
	}
	payload, err := json.Marshal(map[string]string{field: file.PickCode})
	if err != nil {
		return "", errors.New("无法构建 115 下载请求")
	}
	encrypted, err := cloudEncrypt(payload)
	if err != nil {
		return "", errors.New("无法加密 115 下载请求")
	}
	if path == "/app/chrome/downurl" {
		path += "?t=" + strconv.FormatInt(time.Now().Unix(), 10)
	}
	base := c.apiURL
	// The reference uses HTTP; never send the login Cookie in cleartext without opt-in.
	if c.summary().Settings.DownloadHTTP {
		base = strings.Replace(base, "https://", "http://", 1)
	}
	if err := c.requestAt(ctx, base, "POST", path, url.Values{"data": {encrypted}}, ua, &response); err != nil {
		return "", err
	}
	decoded, err := cloudDecrypt(response.Data)
	if err != nil {
		return "", errors.New("无法解密 115 下载响应")
	}
	var direct struct {
		URL      string      `json:"url"`
		FileID   cloudNumber `json:"file_id"`
		PickCode string      `json:"pick_code"`
	}
	if err := json.Unmarshal(decoded, &direct); err == nil && direct.URL != "" {
		if (direct.FileID != "" && string(direct.FileID) != file.FileID) ||
			(direct.PickCode != "" && direct.PickCode != file.PickCode) {
			return "", errors.New("115 返回的文件与请求不一致")
		}
		return checkedCloudLink(direct.URL)
	}
	var entries map[string]struct {
		URL struct {
			URL string `json:"url"`
		} `json:"url"`
	}
	if err := json.Unmarshal(decoded, &entries); err != nil {
		return "", errors.New("无法解析 115 下载响应")
	}
	if len(entries) != 1 {
		return "", errors.New("115 未返回唯一的下载地址")
	}
	for id, entry := range entries {
		if id != file.FileID {
			return "", errors.New("115 返回的文件与请求不一致")
		}
		return checkedCloudLink(entry.URL.URL)
	}
	return "", errors.New("115 下载地址不存在")
}

func checkedCloudLink(link string) (string, error) {
	if !validCloudURL(link) {
		u, _ := url.Parse(link)
		if u != nil {
			return "", fmt.Errorf("115 返回的下载地址不受信任（协议 %s，主机 %s）", u.Scheme, u.Host)
		}
		return "", errors.New("115 返回的下载地址不受信任")
	}
	u, _ := url.Parse(link)
	if flags := u.Query().Get("f"); flags != "" && flags != "0" && flags != "1" {
		return "", errCloudCookieLink
	}
	return link, nil
}

func (c *Cloud115) Schedule() {
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		settings := c.snapshot()
		if settings.Settings.Enabled {
			_ = c.start("resume", "")
		}
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			schedule := c.summary().Settings.syncSchedule()
			next := schedule.next(time.Now())
			var timer *time.Timer
			var tick <-chan time.Time
			if !next.IsZero() {
				timer = time.NewTimer(time.Until(next))
				tick = timer.C
			}
		wait:
			for {
				select {
				case <-c.server.ctx.Done():
					if timer != nil {
						timer.Stop()
					}
					return
				case <-c.scheduleChanged:
					break wait
				case <-tick:
					settings := c.summary()
					if settings.Settings.Enabled && settings.Settings.syncSchedule() == schedule {
						if err := c.start("sync", ""); err != nil {
							c.server.logger.With("category", "strm").Info("115 定时同步已跳过", "reason", err)
						}
					}
					break wait
				case <-ticker.C:
					if err := c.pruneMissingSTRMs(); err != nil {
						c.server.logger.Warn("清理已删除的 STRM 索引失败", "error", err)
					}
				}
			}
			if timer != nil {
				timer.Stop()
			}
		}
	}()
}

func (s CloudSettings) syncSchedule() ScanSchedule {
	if s.SyncSchedule != nil {
		return s.SyncSchedule.daily()
	}
	if s.IntervalMinutes > 0 {
		return ScanSchedule{Mode: "daily", Time: "03:00"}
	}
	return ScanSchedule{Mode: "manual", Time: "03:00"}
}

// busyLocked guards account, settings and metadata changes across both tasks.
func (c *Cloud115) busyLocked() bool { return c.busy || c.probeBusy || c.fileBusy }

func (c *Cloud115) start(mode, trackID string, downloadLyrics ...bool) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.fileBusy {
		return errors.New("115 文件操作正在进行，请完成后重试")
	}
	settings := c.summary()
	if !settings.Settings.Enabled || settings.Cookie == "" || settings.Account == "" {
		return errors.New("请先扫码登录 115 并启用音源")
	}
	if c.server.ctx.Err() != nil {
		return c.server.ctx.Err()
	}
	if mode != "sync" {
		if c.probeStopping {
			return errors.New("预探测正在终止，请停止后再继续")
		}
		if mode == "resume" && settings.ProbePaused {
			return nil
		}
		if c.busy && mode != "resume" {
			return errors.New("请等待 STRM 生成完成后再加入探测队列")
		}
		if err := c.enqueue(mode, trackID); err != nil {
			return err
		}
		if !c.probeBusy && len(c.snapshot().ProbeQueue) > 0 {
			c.probeBusy, c.probeStopping = true, false
			ctx, cancel := context.WithCancel(c.server.ctx)
			c.probeCancel = cancel
			c.wg.Add(1)
			c.server.logger.With("category", "probe").Info("115 预探测任务开始", "mode", mode, "queued", len(c.snapshot().ProbeQueue))
			go c.probeWorker(ctx)
		} else if !c.probeBusy {
			c.probeMessage = "暂无待探测歌曲"
		}
		return nil
	}
	if c.busy {
		return errors.New("STRM 生成任务正在进行，请等待完成")
	}
	if len(downloadLyrics) > 0 {
		if err := c.server.store.updateCloud(func(st *libraryState) error {
			st.Cloud.Settings.DownloadLyrics = downloadLyrics[0]
			return nil
		}); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(c.server.ctx, 30*time.Minute)
	c.syncCancel, c.syncStopping = cancel, false
	c.syncDone, c.syncTotal, c.syncUnchanged = 0, 0, 0
	c.busy, c.message = true, "任务已启动，正在后台读取目录树；可离开页面"
	c.wg.Add(1)
	c.server.logger.With("category", "strm").Info("115 STRM 生成任务开始", "root", settings.Settings.RootID,
		"download_lyrics", c.summary().Settings.DownloadLyrics)
	go func() {
		defer c.wg.Done()
		defer cancel()
		err := c.generate(ctx)
		c.mu.Lock()
		c.busy, c.syncStopping, c.syncCancel = false, false, nil
		if err != nil {
			c.message = err.Error()
			if errors.Is(err, context.Canceled) {
				c.message = "STRM 生成已终止，已生成文件和原有音乐库已保留"
			}
			if errors.Is(err, context.DeadlineExceeded) {
				c.message = "STRM 生成超过 30 分钟，已停止；请缩小目录范围后重试"
			}
		}
		message, done, total, unchanged := c.message, c.syncDone, c.syncTotal, c.syncUnchanged
		c.mu.Unlock()
		logger := c.server.logger.With("category", "strm")
		if err != nil && !errors.Is(err, context.Canceled) {
			logger.Warn("115 STRM 生成未完成", "reason", err, "done", done, "total", total)
		} else {
			logger.Info(message, "done", done, "total", total, "unchanged", unchanged)
		}
	}()
	return nil
}

func (c *Cloud115) generate(ctx context.Context) error {
	if err := c.syncTree(ctx); err != nil {
		return err
	}
	if err := c.generateSTRMs(ctx); err != nil {
		return err
	}
	if c.summary().Settings.DownloadLyrics {
		return c.syncLyrics(ctx)
	}
	return nil
}

func (c *Cloud115) generateSTRMs(ctx context.Context) error {
	c.dataMu.Lock()
	defer c.dataMu.Unlock()
	settings := c.snapshot()
	writer := c.newSTRMWriter()
	defer writer.close()
	c.mu.Lock()
	c.syncTotal, c.syncDone, c.syncUnchanged = 0, 0, 0
	for _, item := range settings.Items {
		if item.Account == settings.Account && item.State != "missing" && item.State != "skipped" {
			c.syncTotal++
		}
	}
	c.mu.Unlock()
	c.server.logger.With("category", "strm").Info("115 目录树读取完成，开始生成 STRM", "total", c.syncTotal)
	generated := 0
	lastLog := time.Now()
	paths := make(map[string]string)
	for id, item := range settings.Items {
		if item.Account != settings.Account || item.State == "missing" || item.State == "skipped" {
			continue
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		path := c.strmPath(item)
		unchanged, err := writer.write(ctx, item, path)
		if err != nil {
			return err
		}
		paths[id] = path
		generated++
		c.mu.Lock()
		c.syncDone = generated
		if unchanged {
			c.syncUnchanged++
		}
		if !c.syncStopping {
			c.message = fmt.Sprintf("正在生成 STRM · %d / %d · 未变化 %d", generated, c.syncTotal, c.syncUnchanged)
		}
		c.mu.Unlock()
		if generated%500 == 0 || time.Since(lastLog) >= 5*time.Second {
			c.server.logger.With("category", "strm").Info("115 STRM 生成进度", "done", generated, "total", len(settings.Items), "file", item.Path)
			lastLog = time.Now()
		}
	}
	c.syncProgress("正在刷新网盘音乐库")
	// Publish basic entries in one commit; tags and artwork can be filled in later.
	if err := c.server.store.updateCloud(func(st *libraryState) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		for id, path := range paths {
			item := st.Cloud.Items[id]
			st.Tracks[id] = cloudSTRMTrack(item, st.Tracks[id], path, st.Cloud.Cookie == "")
		}
		return nil
	}); err != nil {
		return err
	}
	c.mu.Lock()
	c.message = fmt.Sprintf("已生成 %d 个 STRM，网盘音乐库已刷新", generated)
	c.mu.Unlock()
	return nil
}

func (c *Cloud115) setItemState(id, state, message string) error {
	return c.server.store.updateEntry(id, func(st *libraryState) error {
		item := st.Cloud.Items[id]
		item.State, item.Error = state, message
		st.Cloud.Items[id] = item
		return nil
	})
}

func (c *Cloud115) strmPath(item CloudItem) string {
	if track, ok := c.server.store.Track(item.TrackID); ok {
		return track.Path
	}
	return filepath.Join(c.server.config.DataDir, "cloud115", "strm", "tree", item.Account, filepath.Dir(item.Path), item.TrackID, safeComponent(item.Name)+".strm")
}

func (c *Cloud115) publish(item CloudItem, t Track) error {
	t.ID, t.Size, t.Library, t.Unavailable = item.TrackID, item.Size, "cloud", false
	t.AddedAt = time.Now().UTC()
	c.server.store.mu.RLock()
	old := c.server.store.state.Tracks[t.ID]
	c.server.store.mu.RUnlock()
	if old.ID != "" {
		t.Favorite, t.AddedAt = old.Favorite, old.AddedAt
		if old.MetadataLocked {
			metadataOf(old.Track).apply(&t)
			t.MetadataLocked = true
		}
	}
	if _, duplicate, err := c.server.store.duplicateTrack(t); err != nil {
		return err
	} else if duplicate {
		return c.server.store.updateEntry(t.ID, func(st *libraryState) error {
			current := st.Cloud.Items[t.ID]
			current.State, current.Error = "skipped", "同一音乐库已有同名同歌手歌曲，保留远端文件"
			st.Cloud.Items[t.ID] = current
			if old.ID != "" {
				old.Unavailable = true
				st.Tracks[t.ID] = old
			}
			return nil
		})
	}
	source := c.strmPath(item)
	move, err := c.server.scanner.stageTrackMove(c.server.ctx, source, t)
	if err != nil {
		return c.setItemState(t.ID, "failed", "无法整理 STRM，原索引已保留")
	}
	err = c.server.store.updateEntry(t.ID, func(st *libraryState) error {
		embedded, _ := makeLyrics(t.TagLyrics, "embedded")
		remote := item.RemoteFile
		lyrics := old.Lyrics
		if old.ID != "" && lyricsIdentity(old.Track) != lyricsIdentity(t) {
			lyrics = nil
		}
		t.Unavailable = st.Cloud.Cookie == ""
		st.Tracks[t.ID] = DiskTrack{Track: t, File: move.destination, Remote: &remote, Lyrics: lyrics,
			EmbeddedLyrics: embedded, EmbeddedChecked: true}
		current := st.Cloud.Items[t.ID]
		current.State, current.Error = "ready", ""
		st.Cloud.Items[t.ID] = current
		return nil
	})
	if err != nil {
		move.rollback()
		return err
	}
	if err := move.finish(); err != nil {
		c.server.logger.Warn("remove old STRM path", "error", err)
	}
	return nil
}

func (c *Cloud115) probeFile(ctx context.Context, item CloudItem) (Track, error) {
	link, err := c.downloadURL(ctx, item.RemoteFile, probeUserAgent)
	if err != nil {
		return Track{}, err
	}
	t, err := probeMetadata(ctx, link, item.Name, probeUserAgent)
	if err != nil {
		return Track{}, errors.New("远端音频探测失败，请检查音频格式、网络和授权后重试")
	}
	if t.Artist == "" {
		t.Artist = "Unknown Artist"
	}
	if t.AlbumArtist == "" {
		t.AlbumArtist = t.Artist
	}
	if t.Album == "" {
		t.Album = "Unknown Album"
	}
	t.MetadataSource = "tags"
	t.Artwork = c.server.scanner.extractRemoteArtwork(ctx, link, item.TrackID, probeUserAgent)
	if t.Artwork == "" && item.Cover != nil {
		if cover, err := c.downloadURL(ctx, *item.Cover, probeUserAgent); err == nil {
			t.Artwork = c.server.scanner.extractRemoteArtwork(ctx, cover, item.TrackID, probeUserAgent)
		}
	}
	return t, nil
}

func (c *Cloud115) readSidecar(ctx context.Context, file RemoteFile) ([]byte, error) {
	link, err := c.downloadURL(ctx, file, probeUserAgent)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, "GET", link, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", probeUserAgent)
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, errors.New("读取网盘歌词失败")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, errors.New("网盘歌词暂不可用")
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxLyricsSize+1))
	if err != nil || len(data) > maxLyricsSize {
		return nil, errors.New("网盘歌词超过大小限制")
	}
	return data, nil
}
