package resona

import (
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

func (c *Cloud115) routes(mux *http.ServeMux) {
	protect := c.server.protect
	mux.HandleFunc("GET /api/v1/cloud115", protect(c.status))
	mux.HandleFunc("GET /api/v1/cloud115/progress", protect(c.progress))
	mux.HandleFunc("GET /api/v1/cloud115/account", protect(c.account))
	mux.HandleFunc("POST /api/v1/cloud115/sync/stop", protect(c.terminate))
	mux.HandleFunc("POST /api/v1/cloud115/probe/stop", protect(c.terminate))
	mux.HandleFunc("PUT /api/v1/cloud115", protect(c.configure))
	mux.HandleFunc("GET /api/v1/cloud115/folders", protect(c.folders))
	mux.HandleFunc("POST /api/v1/cloud115/auth", protect(c.authorize))
	mux.HandleFunc("GET /api/v1/cloud115/auth", protect(c.authStatus))
	mux.HandleFunc("GET /api/v1/cloud115/auth/qr", protect(c.authQR))
	mux.HandleFunc("POST /api/v1/cloud115/disconnect", protect(c.disconnect))
	mux.HandleFunc("POST /api/v1/cloud115/sync", protect(c.task))
	mux.HandleFunc("POST /api/v1/cloud115/scan", protect(c.scanLocal))
	mux.HandleFunc("POST /api/v1/cloud115/retry", protect(c.task))
	mux.HandleFunc("POST /api/v1/cloud115/probe", protect(c.task))
}

func (c *Cloud115) status(w http.ResponseWriter, r *http.Request) {
	if err := c.pruneMissingSTRMs(); err != nil {
		c.server.logger.Warn("清理已删除的 STRM 索引失败", "error", err)
	}
	settings := c.snapshot()
	schedule := settings.Settings.syncSchedule()
	settings.Settings.SyncSchedule = &schedule
	c.mu.Lock()
	busy, message := c.busyLocked(), c.message
	syncStopping, probeStopping := c.syncStopping, c.probeStopping
	syncBusy, probeBusy, current, probeMessage := c.busy, c.probeBusy, c.probeCurrent, c.probeMessage
	c.mu.Unlock()
	queued := make(map[string]bool, len(settings.ProbeQueue))
	for _, id := range settings.ProbeQueue {
		queued[id] = true
	}
	waiting := len(queued)
	if queued[current] {
		waiting--
	}
	items, counts := []CloudItem{}, map[string]int{}
	for _, item := range settings.Items {
		if item.Account != settings.Account {
			continue
		}
		counts[item.State]++
		item.Queued = queued[item.TrackID]
		if state := r.URL.Query().Get("state"); state == "" || state == item.State {
			items = append(items, item)
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Path < items[j].Path })
	offset := min(parsePositive(r.URL.Query().Get("offset"), 0), len(items))
	limit := min(parsePositive(r.URL.Query().Get("limit"), 100), 500)
	jsonResponse(w, 200, map[string]any{
		"settings": settings.Settings, "connected": settings.Cookie != "", "account": settings.Account,
		"account_name": settings.AccountName, "last_sync": settings.LastSync,
		"timezone": time.Now().Format("MST -07:00"),
		"busy":     busy, "message": message, "sync_busy": syncBusy,
		"sync_stopping": syncStopping, "probe_stopping": probeStopping,
		"probe_busy": probeBusy, "probe_current": current, "probe_queued": waiting, "probe_message": probeMessage, "counts": counts, "total": len(items), "offset": offset,
		"items": items[offset:min(offset+limit, len(items))],
	})
}

func (c *Cloud115) configure(w http.ResponseWriter, r *http.Request) {
	var settings CloudSettings
	if !decodeBody(w, r, &settings) {
		return
	}
	if settings.RootID == "" {
		settings.RootID = "0"
	}
	if settings.SyncSchedule != nil {
		if err := settings.SyncSchedule.validate(); err != nil {
			apiError(w, 400, err.Error())
			return
		}
	}
	settings.BaseURL = strings.TrimRight(strings.TrimSpace(settings.BaseURL), "/")
	if settings.BaseURL == "" {
		scheme := "http"
		if r.TLS != nil {
			scheme = "https"
		}
		settings.BaseURL = (&url.URL{Scheme: scheme, Host: r.Host}).String()
	}
	u, err := url.Parse(settings.BaseURL)
	if !decimalID(settings.RootID) || len(settings.RootPath) > 4096 || settings.IntervalMinutes < 0 || settings.IntervalMinutes > 10080 ||
		err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" ||
		u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		apiError(w, 400, "请选择有效的音乐目录，并填写 Resona 完整访问地址和每日同步时间")
		return
	}
	schedule := settings.syncSchedule()
	settings.SyncSchedule, settings.IntervalMinutes = &schedule, 0
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.busyLocked() {
		apiError(w, 409, "后台任务运行中，请完成后再修改设置")
		return
	}
	select {
	case c.linkGate <- struct{}{}:
		defer func() { <-c.linkGate }()
	case <-r.Context().Done():
		return
	}
	if err := c.server.store.update(func(st *libraryState) error {
		st.Cloud.Settings = settings
		return nil
	}); err != nil {
		apiError(w, 500, "无法保存 115 设置")
		return
	}
	clear(c.links)
	c.downloadPath = ""
	select {
	case c.scheduleChanged <- struct{}{}:
	default:
	}
	jsonResponse(w, 200, settings)
}

func decimalID(value string) bool {
	if value == "" || len(value) > 32 {
		return false
	}
	for _, ch := range value {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	return true
}

func cloudCookie(values map[string]string) (string, string, error) {
	var parts []string
	for _, name := range []string{"UID", "CID", "SEID", "KID"} {
		value := values[name]
		if value == "" && name == "KID" {
			continue
		}
		cookie := &http.Cookie{Name: name, Value: value}
		if value == "" || len(value) > 4096 || cookie.Valid() != nil {
			return "", "", fmt.Errorf("invalid 115 cookie")
		}
		parts = append(parts, name+"="+value)
	}
	account := strings.SplitN(values["UID"], "_", 2)[0]
	if !decimalID(account) || account == "0" {
		return "", "", fmt.Errorf("invalid 115 account")
	}
	return strings.Join(parts, "; "), account, nil
}

func (c *Cloud115) folders(w http.ResponseWriter, r *http.Request) {
	parent := r.URL.Query().Get("parent")
	if parent == "" {
		parent = "0"
	}
	if !decimalID(parent) {
		apiError(w, 400, "目录 ID 无效")
		return
	}
	files, parts, err := c.listDirectory(r.Context(), parent, false)
	if err != nil {
		apiError(w, 502, err.Error())
		return
	}
	type folder struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	breadcrumbs := []folder{{"0", "全部文件"}}
	location := ""
	seen := map[string]bool{"0": true}
	for i, part := range parts {
		id := string(part.ID)
		if i == 0 && id == "0" {
			continue
		}
		if !decimalID(id) || seen[id] || !validCloudTreeName(part.Name) {
			apiError(w, 502, "无法读取目录路径，请重新选择音乐目录")
			return
		}
		seen[id] = true
		location += "/" + part.Name
		breadcrumbs = append(breadcrumbs, folder{id, part.Name})
	}
	if breadcrumbs[len(breadcrumbs)-1].ID != parent || (parent != "0" && (len(parts) == 0 || parts[0].ID != "0")) {
		apiError(w, 502, "115 未返回完整目录路径，请从全部文件重新选择")
		return
	}
	if location == "" {
		location = "/"
	}
	if _, err := cloudManagedPath(location); err != nil {
		apiError(w, 502, "115 返回的目录路径无效，请重新选择音乐目录")
		return
	}
	out := []folder{}
	for _, f := range files {
		if f.Category == "0" {
			out = append(out, folder{string(f.ID), f.Name})
		}
	}
	jsonResponse(w, 200, map[string]any{"items": out, "parent": parent, "path": location, "breadcrumbs": breadcrumbs})
}

func (c *Cloud115) authorize(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ClientType string `json:"client_type"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	if body.ClientType == "" {
		body.ClientType = "alipaymini"
	}
	switch body.ClientType {
	case "alipaymini", "wechatmini", "115android", "115ios", "web", "115ipad", "tv":
	default:
		apiError(w, 400, "请选择有效的 115 扫码方式")
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.busyLocked() {
		apiError(w, 409, "后台任务运行中，请稍后扫码登录")
		return
	}
	var result struct {
		Data struct {
			UID    string      `json:"uid"`
			Time   cloudNumber `json:"time"`
			Sign   string      `json:"sign"`
			QRCode string      `json:"qrcode"`
		} `json:"data"`
	}
	if err := c.raw(r.Context(), "GET", c.qrURL+"/api/1.0/web/1.0/token/", nil, "", "", &result); err != nil {
		apiError(w, 502, err.Error())
		return
	}
	if result.Data.QRCode == "" {
		result.Data.QRCode = "https://115.com/scan/dg-" + url.PathEscape(result.Data.UID)
	}
	u, err := url.Parse(result.Data.QRCode)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host != "115.com" || u.User != nil || result.Data.UID == "" || result.Data.Sign == "" || !decimalID(string(result.Data.Time)) {
		apiError(w, 502, "115 未返回有效的登录二维码")
		return
	}
	c.auth = cloudAuth{UID: result.Data.UID, Sign: result.Data.Sign, Time: string(result.Data.Time),
		ClientType: body.ClientType, URL: result.Data.QRCode, Expires: time.Now().Add(5 * time.Minute)}
	jsonResponse(w, 200, map[string]any{"url": c.auth.URL, "expires_at": c.auth.Expires, "client_type": c.auth.ClientType})
}

func (c *Cloud115) authQR(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	auth := c.auth
	c.mu.Unlock()
	if auth.URL == "" || time.Now().After(auth.Expires) {
		apiError(w, 410, "登录二维码已过期，请重新获取")
		return
	}
	data, err := cloudQRCode(auth.URL)
	if err != nil {
		apiError(w, 500, "无法生成二维码")
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Write(data)
}

func (c *Cloud115) authStatus(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	auth, busy := c.auth, c.busyLocked()
	c.mu.Unlock()
	if busy {
		apiError(w, 409, "后台任务运行中，请完成后再扫码登录")
		return
	}
	if auth.UID == "" || time.Now().After(auth.Expires) {
		apiError(w, 410, "登录二维码已过期，请重新获取")
		return
	}
	var response struct {
		Data struct {
			Status int `json:"status"`
		} `json:"data"`
	}
	if err := c.raw(r.Context(), "GET", c.qrURL+"/get/status/", url.Values{
		"uid": {auth.UID}, "time": {auth.Time}, "sign": {auth.Sign},
	}, "", "", &response); err != nil {
		apiError(w, 502, err.Error())
		return
	}
	// Do not block QR refresh while waiting for an upstream long poll.
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.busyLocked() || c.auth.UID != auth.UID || c.auth.ClientType != auth.ClientType {
		apiError(w, 409, "扫码会话已更换或后台任务已开始，请使用当前二维码重试")
		return
	}
	if response.Data.Status != 2 {
		if response.Data.Status < 0 {
			c.auth = cloudAuth{}
		}
		jsonResponse(w, 200, map[string]any{"status": response.Data.Status})
		return
	}
	var result struct {
		Data struct {
			Cookie map[string]string `json:"cookie"`
		} `json:"data"`
	}
	// Bind the device to the QR session, never to a later polling query.
	if err := c.raw(r.Context(), "POST", c.qrURL+"/app/1.0/"+auth.ClientType+"/1.0/login/qrcode/",
		url.Values{"account": {auth.UID}}, "", "", &result); err != nil {
		apiError(w, 502, err.Error())
		return
	}
	var user struct {
		Data struct {
			ID   cloudNumber `json:"user_id"`
			Name string      `json:"user_name"`
		} `json:"data"`
	}
	cookie, account, err := cloudCookie(result.Data.Cookie)
	if err != nil {
		apiError(w, 502, "115 未返回有效的登录 Cookie")
		return
	}
	if err := c.raw(r.Context(), "GET", c.userURL+"/", url.Values{"ct": {"ajax"}, "ac": {"nav"}}, cookie, "", &user); err != nil {
		apiError(w, 502, err.Error())
		return
	}
	if string(user.Data.ID) != account {
		apiError(w, 502, "115 返回的账号标识无效")
		return
	}
	if err := c.server.store.update(func(st *libraryState) error {
		st.Cloud.Account, st.Cloud.AccountName = string(user.Data.ID), user.Data.Name
		st.Cloud.Cookie = cookie
		for id, track := range st.Tracks {
			if track.Remote != nil {
				track.Unavailable = track.Remote.Account != st.Cloud.Account || st.Cloud.Items[id].State == "missing" || st.Cloud.Items[id].State == "skipped"
				st.Tracks[id] = track
			}
		}
		return nil
	}); err != nil {
		apiError(w, 500, "无法保存 115 登录状态，请重新扫码")
		return
	}
	c.auth = cloudAuth{}
	c.linkGate <- struct{}{}
	clear(c.links)
	c.downloadPath = ""
	<-c.linkGate
	jsonResponse(w, 200, map[string]any{"status": 2, "account_name": user.Data.Name})
}

func (c *Cloud115) disconnect(w http.ResponseWriter, r *http.Request) {
	var body struct{}
	if !decodeBody(w, r, &body) {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.busyLocked() {
		apiError(w, 409, "后台任务运行中，请完成后再断开")
		return
	}
	err := c.server.store.update(func(st *libraryState) error {
		st.Cloud.Cookie = ""
		st.Cloud.Settings.Enabled = false
		for id, track := range st.Tracks {
			if track.Remote != nil {
				track.Unavailable = true
				st.Tracks[id] = track
			}
		}
		return nil
	})
	if err != nil {
		apiError(w, 500, "无法保存断开状态")
		return
	}
	c.auth = cloudAuth{}
	c.linkGate <- struct{}{}
	clear(c.links)
	c.downloadPath = ""
	<-c.linkGate
	jsonResponse(w, 200, map[string]bool{"ok": true})
}

func (c *Cloud115) task(w http.ResponseWriter, r *http.Request) {
	var body struct {
		TrackID        string `json:"track_id"`
		DownloadLyrics *bool  `json:"download_lyrics"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	mode := "sync"
	if strings.HasSuffix(r.URL.Path, "/retry") {
		mode = "retry"
	}
	if strings.HasSuffix(r.URL.Path, "/probe") {
		mode = "probe"
	}
	if mode == "sync" && body.TrackID != "" {
		apiError(w, 400, "生成任务不接受单曲标识")
		return
	}
	if body.TrackID != "" {
		if !validHex(body.TrackID, 64) {
			apiError(w, 400, "歌曲标识无效")
			return
		}
		if _, ok := c.snapshot().Items[body.TrackID]; !ok {
			apiError(w, 404, "歌曲不存在")
			return
		}
	}
	var options []bool
	if mode == "sync" && body.DownloadLyrics != nil {
		options = append(options, *body.DownloadLyrics)
	}
	if err := c.start(mode, body.TrackID, options...); err != nil {
		apiError(w, 409, err.Error())
		return
	}
	jsonResponse(w, 202, map[string]bool{"started": true})
}

// A local encoder keeps authorization URLs away from third-party QR services.
func cloudQRCode(value string) ([]byte, error) {
	return qrcode.Encode(value, qrcode.Medium, 256)
}
