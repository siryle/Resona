// SPDX-License-Identifier: GPL-3.0-only
// Port of Seed680's MusicSaverBot and TelegramLocalApi behavior; see THIRD_PARTY.md.
package resona

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type MusicSaverSettings struct {
	Enabled   bool   `json:"enabled"`
	Token     string `json:"token"`
	APIURL    string `json:"api_url"`
	Whitelist string `json:"whitelist"`
}

type TelegramSettings struct {
	Enabled       bool   `json:"enabled"`
	APIID         int    `json:"api_id"`
	APIHash       string `json:"api_hash"`
	Port          int    `json:"port"`
	ProxyType     string `json:"proxy_type"`
	ProxyHost     string `json:"proxy_host"`
	ProxyPort     int    `json:"proxy_port"`
	ProxyUser     string `json:"proxy_user"`
	ProxyPassword string `json:"proxy_password"`
	Log           bool   `json:"log"`
	CleanupHours  int    `json:"cleanup_hours"`
}

type PluginSettings struct {
	Music    MusicSaverSettings `json:"musicsaverbot"`
	Telegram TelegramSettings   `json:"telegramlocalapi"`
	Offset   int64              `json:"offset"`
}

type pluginStatus struct {
	State     string `json:"state"`
	Message   string `json:"message"`
	LastSaved string `json:"last_saved,omitempty"`
}

type Plugins struct {
	server       *Server
	client       *http.Client
	op           sync.Mutex
	mu           sync.RWMutex
	status       map[string]pluginStatus
	workers      map[string]pluginWorker
	connectLocal localTelegramConnector
}

type pluginWorker struct {
	cancel context.CancelFunc
	done   chan struct{}
}

func newPlugins(s *Server) *Plugins {
	return &Plugins{server: s, client: &http.Client{Timeout: 65 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
		status: map[string]pluginStatus{}, workers: map[string]pluginWorker{}, connectLocal: connectNativeTelegram}
}

func (s *Store) pluginSettings() PluginSettings {
	s.mu.RLock()
	defer s.mu.RUnlock()
	settings := s.state.Plugins
	if settings.Telegram.Port == 0 {
		settings.Telegram.Port = 8081
	}
	return settings
}

func (s *Store) pluginInbox(c Config) string {
	return filepath.Join(c.DataDir, "plugins", "musicsaverbot", "inbox")
}

func (p *Plugins) setStatus(id, state, message string) {
	p.mu.Lock()
	status := p.status[id]
	changed := status.State != state || status.Message != message
	status.State, status.Message = state, message
	p.status[id] = status
	p.mu.Unlock()
	if changed {
		logger := p.server.logger.With("category", "plugin", "plugin", id)
		if state == "error" {
			logger.Error(message)
		} else {
			logger.Info(message, "state", state)
		}
	}
}

func (p *Plugins) Start() {
	p.op.Lock()
	defer p.op.Unlock()
	p.restart()
}

func (p *Plugins) Wait() {
	p.op.Lock()
	defer p.op.Unlock()
	p.stop()
}

func (p *Plugins) stop(ids ...string) {
	if len(ids) == 0 {
		ids = []string{"musicsaverbot", "telegramlocalapi"}
	}
	for _, id := range ids {
		if worker, ok := p.workers[id]; ok {
			worker.cancel()
			<-worker.done
			delete(p.workers, id)
		}
	}
}

// Restart waits for downloads and the child process to stop before starting replacements.
func (p *Plugins) restart(ids ...string) {
	settings := p.server.store.pluginSettings()
	wanted := map[string]bool{}
	if len(ids) == 0 {
		ids = []string{"musicsaverbot", "telegramlocalapi"}
	}
	for _, id := range ids {
		wanted[id] = true
	}
	if wanted["telegramlocalapi"] && settings.Music.APIURL == "local" {
		wanted["musicsaverbot"] = true
	}
	for _, id := range []string{"musicsaverbot", "telegramlocalapi"} {
		if wanted[id] {
			p.stop(id)
		}
	}
	settings = p.server.store.pluginSettings()
	for _, id := range []string{"telegramlocalapi", "musicsaverbot"} {
		if !wanted[id] {
			continue
		}
		p.setStatus(id, "disabled", "已停用")
		var run func(context.Context)
		if id == "telegramlocalapi" && settings.Telegram.Enabled {
			run = func(ctx context.Context) { p.runLocalAPI(ctx, settings.Telegram) }
		} else if id == "musicsaverbot" && settings.Music.Enabled {
			run = func(ctx context.Context) { p.runBot(ctx, settings) }
		}
		if run != nil {
			p.setStatus(id, "starting", "正在启动")
			ctx, cancel := context.WithCancel(p.server.ctx)
			done := make(chan struct{})
			p.workers[id] = pluginWorker{cancel: cancel, done: done}
			go func() { defer close(done); run(ctx) }()
		}
	}
}

func (p *Plugins) list(w http.ResponseWriter, r *http.Request) {
	settings := p.server.store.pluginSettings()
	hasToken, hasHash, hasProxy := settings.Music.Token != "", settings.Telegram.APIHash != "", settings.Telegram.ProxyPassword != ""
	settings.Music.Token, settings.Telegram.APIHash, settings.Telegram.ProxyPassword = "", "", ""
	p.mu.RLock()
	defer p.mu.RUnlock()
	status := func(id string) pluginStatus {
		if s, ok := p.status[id]; ok {
			return s
		}
		return pluginStatus{State: "disabled", Message: "已停用"}
	}
	jsonResponse(w, 200, map[string]any{"items": []any{
		map[string]any{"id": "musicsaverbot", "name": "音乐保存机器人", "version": "1.0.45", "author": "Seed680",
			"description": "接收 Telegram 音频、歌词与封面，保存到本地并自动加入音乐库。",
			"config":      settings.Music, "has_token": hasToken, "status": status("musicsaverbot"),
			"save_path": p.server.store.pluginInbox(p.server.config)},
		map[string]any{"id": "telegramlocalapi", "name": "Telegram 本地 API", "version": "1.0.12", "author": "Seed680",
			"description": "运行本地 Bot API 服务，支持大文件下载、代理与缓存清理。",
			"config":      settings.Telegram, "has_api_hash": hasHash, "has_proxy_password": hasProxy, "status": status("telegramlocalapi"),
			"native": true, "data_path": p.localDir()},
	}})
}

var botTokenPattern = regexp.MustCompile(`^[0-9]+:[A-Za-z0-9_-]{20,128}$`)
var apiHashPattern = regexp.MustCompile(`^[a-fA-F0-9]{32}$`)

func (p *Plugins) configure(w http.ResponseWriter, r *http.Request) {
	p.op.Lock()
	defer p.op.Unlock()
	settings := p.server.store.pluginSettings()
	previousToken := settings.Music.Token
	switch r.PathValue("id") {
	case "musicsaverbot":
		var next MusicSaverSettings
		if !decodeBody(w, r, &next) {
			return
		}
		next.Token = strings.TrimSpace(next.Token)
		if next.Token == "" {
			next.Token = settings.Music.Token
		}
		next.APIURL = strings.TrimRight(strings.TrimSpace(next.APIURL), "/")
		if next.Token != "" && !botTokenPattern.MatchString(next.Token) {
			apiError(w, 400, "Bot Token 格式无效")
			return
		}
		if next.APIURL != "" && next.APIURL != "local" {
			u, err := url.Parse(next.APIURL)
			if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" ||
				(u.Scheme != "http" && u.Scheme != "https") {
				apiError(w, 400, "API 地址应为不含凭据或查询参数的 HTTP / HTTPS 地址，或 local")
				return
			}
		}
		for _, id := range strings.Fields(next.Whitelist) {
			if user, err := strconv.ParseInt(id, 10, 64); err != nil || user <= 0 {
				apiError(w, 400, "白名单应为 Telegram 用户 ID，每行一个正整数")
				return
			}
		}
		if next.Enabled && (next.Token == "" || (next.APIURL == "local" && !settings.Telegram.Enabled)) {
			apiError(w, 400, "请填写 Bot Token；使用内置本地 API 时请先启用本地 API 插件")
			return
		}
		if next.Token != settings.Music.Token {
			settings.Offset = 0
		}
		settings.Music = next
	case "telegramlocalapi":
		var next TelegramSettings
		if !decodeBody(w, r, &next) {
			return
		}
		if next.APIHash == "" {
			next.APIHash = settings.Telegram.APIHash
		}
		if next.ProxyPassword == "" {
			next.ProxyPassword = settings.Telegram.ProxyPassword
		}
		if next.Port < 1024 || next.Port > 65535 || next.APIID < 0 || next.APIID > 2147483647 || next.CleanupHours < 0 || next.CleanupHours > 8760 ||
			(next.APIHash != "" && !apiHashPattern.MatchString(next.APIHash)) ||
			(next.ProxyType != "" && next.ProxyType != "http" && next.ProxyType != "socks5") ||
			(next.ProxyType != "" && (next.ProxyHost == "" || next.ProxyPort < 1 || next.ProxyPort > 65535)) ||
			strings.ContainsAny(next.ProxyHost+next.ProxyUser+next.ProxyPassword, "\x00\r\n") {
			apiError(w, 400, "请检查端口、API ID / Hash、代理和缓存清理间隔")
			return
		}
		if next.Enabled && (next.APIID <= 0 || next.APIHash == "") {
			apiError(w, 400, "请填写 Telegram API ID / Hash")
			return
		}
		if !next.Enabled && settings.Music.Enabled && settings.Music.APIURL == "local" {
			apiError(w, 409, "音乐保存机器人正在使用本地 API，请先停用机器人或切换 API 地址")
			return
		}
		settings.Telegram = next
	default:
		apiError(w, 404, "插件不存在")
		return
	}
	if err := p.server.store.update(func(st *libraryState) error {
		// Polling may have advanced while the form was being validated.
		if settings.Music.Token == st.Plugins.Music.Token {
			settings.Offset = st.Plugins.Offset
		}
		st.Plugins = settings
		return nil
	}); err != nil {
		apiError(w, 500, "无法保存插件配置")
		return
	}
	p.server.logbook.registerSecrets(settings)
	p.server.logger.With("category", "plugin").Info("插件设置已保存", "plugin", r.PathValue("id"))
	if settings.Music.Token != previousToken && settings.Telegram.Enabled {
		p.restart("telegramlocalapi", "musicsaverbot")
	} else {
		p.restart(r.PathValue("id"))
	}
	p.list(w, r)
}

func (p *Plugins) action(w http.ResponseWriter, r *http.Request) {
	id, action := r.PathValue("id"), r.PathValue("action")
	if id != "musicsaverbot" && id != "telegramlocalapi" {
		apiError(w, 404, "插件不存在")
		return
	}
	p.op.Lock()
	defer p.op.Unlock()
	switch action {
	case "restart":
		p.restart(id)
	case "logout-cloud":
		if id != "musicsaverbot" {
			apiError(w, 404, "操作不存在")
			return
		}
		settings := p.server.store.pluginSettings()
		if settings.Music.Token == "" || settings.Music.Enabled {
			apiError(w, 409, "请先保存 Token 并停用机器人，再迁移到本地 API")
			return
		}
		if err := p.telegram(r.Context(), "https://api.telegram.org", settings.Music.Token, "logOut", nil, nil); err != nil {
			apiError(w, 502, "Telegram 云端注销失败，请稍后重试")
			return
		}
	case "clean-cache":
		if id != "telegramlocalapi" {
			apiError(w, 404, "操作不存在")
			return
		}
		p.stop()
		err := p.cleanCache()
		p.restart()
		if err != nil {
			apiError(w, 500, "无法清理本地 API 缓存")
			return
		}
	default:
		apiError(w, 404, "操作不存在")
		return
	}
	p.server.logger.With("category", "plugin").Info("插件操作已完成", "plugin", id, "action", action)
	p.list(w, r)
}

func (p *Plugins) localDir() string {
	return filepath.Join(p.server.config.DataDir, "plugins", "telegramlocalapi")
}

func pausePlugin(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func (p *Plugins) cleanCache() error {
	root := filepath.Join(p.localDir(), "files")
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Type().IsRegular() {
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if time.Since(info.ModTime()) > 24*time.Hour {
				return os.Remove(path)
			}
		}
		return nil
	})
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
