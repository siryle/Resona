// SPDX-License-Identifier: GPL-3.0-only
package resona

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	tg "github.com/amarnathcjd/gogram/telegram"
)

// This is the three-method Bot API subset Resona uses, backed by native MTProto.
// Pending messages persist before being made available to the music saver.
type localTelegramUpdate struct {
	ID      int64                        `json:"update_id"`
	Message *telegramMessage             `json:"message"`
	Files   map[string]localTelegramFile `json:"files,omitempty"`
}

type localTelegramFile struct {
	ID, AccessHash int64
	Reference      []byte
	DC             int32
	Size           int64
	Thumb          string
}

type localTelegramState struct {
	Next    int64
	Updates []localTelegramUpdate
}

type localTelegramTransport interface {
	Download(context.Context, localTelegramFile, *os.File) error
	Send(int64, string) error
	Close()
}

type localTelegramConnector func(context.Context, TelegramSettings, string, string, func(*tg.NewMessage) error) (localTelegramTransport, error)

type localBotAPI struct {
	plugins *Plugins
	config  TelegramSettings
	ctx     context.Context
	mu      sync.Mutex
	login   sync.Mutex
	logMu   sync.Mutex
	state   localTelegramState
	path    string
	token   string
	client  localTelegramTransport
	wake    chan struct{}
}

func (p *Plugins) runLocalAPI(ctx context.Context, c TelegramSettings) {
	dir := p.localDir()
	if err := os.MkdirAll(dir, 0700); err != nil {
		p.setStatus("telegramlocalapi", "error", "无法创建本地 API 数据目录")
		return
	}
	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", c.Port))
	if err != nil {
		p.setStatus("telegramlocalapi", "error", "本地 API 端口不可用，请检查端口设置")
		return
	}
	api := &localBotAPI{plugins: p, config: c, ctx: ctx, wake: make(chan struct{}, 1)}
	server := &http.Server{Handler: api, ReadHeaderTimeout: 5 * time.Second,
		BaseContext: func(net.Listener) context.Context { return ctx }}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	defer func() {
		_ = server.Close()
		api.login.Lock()
		defer api.login.Unlock()
		if api.client != nil {
			api.client.Close()
		}
	}()
	p.setStatus("telegramlocalapi", "running", "Go 本地 API 已就绪，仅监听回环地址")
	api.log("Go local API started")
	var cleanup <-chan time.Time
	if c.CleanupHours > 0 {
		ticker := time.NewTicker(time.Duration(c.CleanupHours) * time.Hour)
		defer ticker.Stop()
		cleanup = ticker.C
	}
	for {
		select {
		case <-ctx.Done():
			shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_ = server.Shutdown(shutdown)
			cancel()
			return
		case <-done:
			p.setStatus("telegramlocalapi", "error", "Go 本地 API 已停止，请重启插件")
			return
		case <-cleanup:
			if err := p.cleanCache(); err != nil {
				p.setStatus("telegramlocalapi", "error", "无法清理本地 API 缓存")
			}
		}
	}
}

func (a *localBotAPI) connect(token string) error {
	a.login.Lock()
	defer a.login.Unlock()
	if a.client != nil && a.token == token {
		return nil
	}
	if a.token != "" && a.token != token {
		return errors.New("restart required after token change")
	}
	dir := filepath.Join(a.plugins.localDir(), fmt.Sprintf("%x", sha256.Sum256([]byte(token))))
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	a.mu.Lock()
	a.path = filepath.Join(dir, "pending.json")
	a.state = localTelegramState{Next: a.plugins.server.store.pluginSettings().Offset}
	if data, err := os.ReadFile(a.path); err == nil {
		err = json.Unmarshal(data, &a.state)
		if err != nil {
			a.mu.Unlock()
			return errors.New("本地接收队列损坏，请恢复数据备份")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		a.mu.Unlock()
		return err
	}
	a.token = token
	a.mu.Unlock()
	client, err := a.plugins.connectLocal(a.ctx, a.config, token, dir, a.accept)
	if err != nil {
		a.plugins.setStatus("telegramlocalapi", "error", "Go Telegram 连接失败，请检查 API 凭据、代理和网络")
		return errors.New("无法连接 Telegram")
	}
	a.client = client
	a.log("MTProto connected")
	a.plugins.setStatus("telegramlocalapi", "running", "Go MTProto 已连接")
	return nil
}

func (a *localBotAPI) log(message string) {
	if !a.config.Log {
		return
	}
	a.logMu.Lock()
	defer a.logMu.Unlock()
	path := filepath.Join(a.plugins.localDir(), "service.log")
	flags := os.O_CREATE | os.O_WRONLY | os.O_APPEND
	if info, err := os.Stat(path); err == nil && info.Size() > 10<<20 {
		flags = os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	}
	if file, err := os.OpenFile(path, flags, 0600); err == nil {
		_, _ = fmt.Fprintln(file, time.Now().UTC().Format(time.RFC3339), message)
		_ = file.Close()
	}
}

func localMessage(m *tg.NewMessage) *localTelegramUpdate {
	if m == nil || m.Message == nil || m.Message.Out {
		return nil
	}
	media, ok := m.Message.Media.(*tg.MessageMediaDocument)
	if !ok || media == nil {
		return nil
	}
	doc, ok := media.Document.(*tg.DocumentObj)
	if !ok || doc == nil || doc.Size <= 0 || doc.Size > 2<<30 {
		return nil
	}
	file := &telegramFile{ID: strconv.FormatInt(doc.ID, 10), Size: doc.Size, Mime: doc.MimeType}
	message := &telegramMessage{ID: int64(m.ID), Caption: m.Message.Message, Document: file}
	message.From.ID, message.Chat.ID = m.SenderID(), m.ChannelID()
	for _, attribute := range doc.Attributes {
		switch value := attribute.(type) {
		case *tg.DocumentAttributeFilename:
			file.Name = value.FileName
		case *tg.DocumentAttributeAudio:
			file.Title, file.Performer = value.Title, value.Performer
			message.Document = nil
			if value.Voice {
				message.Voice = file
			} else {
				message.Audio = file
			}
		}
	}
	ext := strings.ToLower(filepath.Ext(file.Name))
	if message.Audio == nil && message.Voice == nil && !supported(file.Name) && ext != ".lrc" && ext != ".txt" {
		return nil
	}
	limit := int64(2 << 30)
	if ext == ".lrc" || ext == ".txt" {
		limit = maxLyricsSize
	}
	if doc.Size > limit {
		return nil
	}
	descriptor := localTelegramFile{ID: doc.ID, AccessHash: doc.AccessHash, Reference: doc.FileReference, DC: doc.DcID, Size: doc.Size}
	update := &localTelegramUpdate{Message: message, Files: map[string]localTelegramFile{file.ID: descriptor}}
	for _, thumb := range doc.Thumbs {
		if size, ok := thumb.(*tg.PhotoSizeObj); ok && size.Size > 0 && size.Size <= 5<<20 {
			copy := descriptor
			copy.Size, copy.Thumb = int64(size.Size), size.Type
			file.Thumbnail = &telegramFile{ID: file.ID + "-" + size.Type, Size: copy.Size}
			update.Files[file.Thumbnail.ID] = copy
			break
		}
	}
	return update
}

func (a *localBotAPI) accept(m *tg.NewMessage) error {
	update := localMessage(m)
	if update == nil || !telegramUserAllowed(a.plugins.server.store.pluginSettings().Music.Whitelist, update.Message.From.ID) {
		return nil
	}
	for a.ctx.Err() == nil {
		a.mu.Lock()
		duplicate := false
		for _, pending := range a.state.Updates {
			if pending.Message.ID == update.Message.ID && pending.Message.Chat.ID == update.Message.Chat.ID {
				duplicate = true
			}
		}
		if duplicate {
			a.mu.Unlock()
			return nil
		}
		if len(a.state.Updates) < 1000 {
			next := localTelegramState{Next: a.state.Next + 1, Updates: append(append([]localTelegramUpdate{}, a.state.Updates...), *update)}
			next.Updates[len(next.Updates)-1].ID = a.state.Next
			if err := atomicJSON(a.path, next); err == nil {
				a.state = next
				a.mu.Unlock()
				select {
				case a.wake <- struct{}{}:
				default:
				}
				return nil
			}
		}
		a.mu.Unlock()
		a.plugins.setStatus("telegramlocalapi", "error", "接收队列已满或无法保存，等待整理后重试")
		if !pausePlugin(a.ctx, time.Second) {
			break
		}
	}
	return a.ctx.Err()
}

func (a *localBotAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/"), "/")
	token := a.plugins.server.store.pluginSettings().Music.Token
	if r.Method != http.MethodPost || len(parts) != 2 || token == "" ||
		subtle.ConstantTimeCompare([]byte(parts[0]), []byte("bot"+token)) != 1 {
		jsonResponse(w, 401, map[string]any{"ok": false})
		return
	}
	if parts[1] != "getUpdates" && parts[1] != "getFile" && parts[1] != "sendMessage" {
		jsonResponse(w, 404, map[string]any{"ok": false})
		return
	}
	if err := a.connect(token); err != nil {
		jsonResponse(w, 502, map[string]any{"ok": false})
		return
	}
	var body struct {
		Offset  int64  `json:"offset"`
		Timeout int    `json:"timeout"`
		Limit   int    `json:"limit"`
		FileID  string `json:"file_id"`
		ChatID  int64  `json:"chat_id"`
		Text    string `json:"text"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&body) != nil {
		jsonResponse(w, 400, map[string]any{"ok": false})
		return
	}
	var result any
	var err error
	switch parts[1] {
	case "getUpdates":
		result, err = a.poll(r.Context(), body.Offset, body.Limit, body.Timeout)
	case "getFile":
		result, err = a.download(r.Context(), body.FileID)
	case "sendMessage":
		if body.ChatID == 0 || len(body.Text) > 4096 {
			err = errors.New("invalid message")
		} else {
			err = a.client.Send(body.ChatID, body.Text)
			result = true
		}
	}
	if err != nil {
		jsonResponse(w, 502, map[string]any{"ok": false})
		return
	}
	jsonResponse(w, 200, map[string]any{"ok": true, "result": result})
}

func (a *localBotAPI) poll(ctx context.Context, offset int64, limit, timeout int) ([]localTelegramUpdate, error) {
	timer := time.NewTimer(time.Duration(min(max(timeout, 0), 25)) * time.Second)
	defer timer.Stop()
	for {
		a.mu.Lock()
		next := localTelegramState{Next: max(a.state.Next, offset)}
		for _, update := range a.state.Updates {
			if update.ID >= offset {
				next.Updates = append(next.Updates, update)
			}
		}
		if len(next.Updates) != len(a.state.Updates) || next.Next != a.state.Next {
			if err := atomicJSON(a.path, next); err != nil {
				a.mu.Unlock()
				return nil, err
			}
			a.state = next
		}
		items := append([]localTelegramUpdate{}, a.state.Updates[:min(max(limit, 1), 100, len(a.state.Updates))]...)
		a.mu.Unlock()
		// File references are private local metadata, not part of the Bot API response.
		for i := range items {
			items[i].Files = nil
		}
		if len(items) > 0 {
			return items, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timer.C:
			return items, nil
		case <-a.wake:
		}
	}
}

type boundedTelegramWriter struct {
	file  *os.File
	limit int64
}

func (w boundedTelegramWriter) WriteAt(data []byte, offset int64) (int, error) {
	if offset < 0 || offset > w.limit || int64(len(data)) > w.limit-offset {
		return 0, io.ErrShortWrite
	}
	return w.file.WriteAt(data, offset)
}

func (a *localBotAPI) download(ctx context.Context, id string) (telegramFile, error) {
	a.mu.Lock()
	var file localTelegramFile
	for _, update := range a.state.Updates {
		if found, ok := update.Files[id]; ok {
			file = found
			break
		}
	}
	a.mu.Unlock()
	if file.Size <= 0 || file.Size > 2<<30 {
		return telegramFile{}, errors.New("unknown file")
	}
	dir := filepath.Join(a.plugins.localDir(), "files")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return telegramFile{}, err
	}
	dest := filepath.Join(dir, fmt.Sprintf("%x", sha256.Sum256([]byte(a.token+id))))
	if info, err := os.Lstat(dest); err == nil && info.Mode().IsRegular() && info.Size() == file.Size {
		return telegramFile{Path: dest, Size: file.Size}, nil
	}
	out, err := os.CreateTemp(dir, ".download-*")
	if err != nil {
		return telegramFile{}, err
	}
	defer os.Remove(out.Name())
	defer out.Close()
	if err := a.client.Download(ctx, file, out); err != nil {
		return telegramFile{}, err
	}
	info, err := out.Stat()
	if err != nil || info.Size() != file.Size {
		return telegramFile{}, errors.New("incomplete download")
	}
	if err := out.Sync(); err != nil {
		return telegramFile{}, err
	}
	if err := out.Close(); err != nil {
		return telegramFile{}, err
	}
	if err := os.Rename(out.Name(), dest); err != nil {
		return telegramFile{}, err
	}
	a.log("Telegram file cached")
	return telegramFile{Path: dest, Size: file.Size}, nil
}

type nativeTelegram struct {
	client *tg.Client
	stop   func() bool
}

func connectNativeTelegram(ctx context.Context, c TelegramSettings, token, dir string, accept func(*tg.NewMessage) error) (localTelegramTransport, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	logger := tg.NewDefaultLogger("Resona Telegram").SetOutput(io.Discard).SetLevel(tg.LogNone)
	cache := tg.NewCache(filepath.Join(dir, "peers.db"), &tg.CacheConfig{Logger: logger})
	config := tg.ClientConfig{AppID: int32(c.APIID), AppHash: c.APIHash, Session: filepath.Join(dir, "session"),
		Cache: cache, Logger: logger, NoPreconnect: true, Timeout: 15, ReqTimeout: 30, UpdateWorkers: 1, UpdateQueueSize: 1000}
	switch c.ProxyType {
	case "http":
		config.Proxy = &tg.HttpProxy{BaseProxy: tg.BaseProxy{Host: c.ProxyHost, Port: c.ProxyPort}, Username: c.ProxyUser, Password: c.ProxyPassword}
	case "socks5":
		config.Proxy = &tg.Socks5Proxy{BaseProxy: tg.BaseProxy{Host: c.ProxyHost, Port: c.ProxyPort}, Username: c.ProxyUser, Password: c.ProxyPassword}
	}
	client, err := tg.NewClient(config)
	if err != nil {
		_ = cache.Close()
		return nil, errors.New("Telegram client initialization failed")
	}
	stop := context.AfterFunc(ctx, func() { _ = client.Stop() })
	client.AddMessageHandler(tg.OnNewMessage, accept)
	if err := client.LoginBot(token); err != nil {
		stop()
		_ = client.Stop()
		_ = cache.Close()
		return nil, errors.New("Telegram authentication failed")
	}
	return &nativeTelegram{client: client, stop: stop}, nil
}

func (n *nativeTelegram) Close() {
	n.stop()
	_ = n.client.Stop()
	_ = n.client.Cache.Close()
}

func (n *nativeTelegram) Send(chat int64, text string) error {
	_, err := n.client.SendMessage(chat, text)
	return err
}

func (n *nativeTelegram) Download(ctx context.Context, f localTelegramFile, out *os.File) error {
	doc := &tg.DocumentObj{ID: f.ID, AccessHash: f.AccessHash, FileReference: f.Reference, DcID: f.DC, Size: f.Size}
	options := &tg.DownloadOptions{Ctx: ctx, Buffer: boundedTelegramWriter{file: out, limit: f.Size}, Threads: 2}
	if f.Thumb != "" {
		thumb := &tg.PhotoSizeObj{Type: f.Thumb, Size: int32(f.Size)}
		doc.Thumbs = []tg.PhotoSize{thumb}
		options.ThumbOnly, options.ThumbSize = true, thumb
	}
	_, err := n.client.DownloadMedia(doc, options)
	return err
}
