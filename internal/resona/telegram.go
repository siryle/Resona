// SPDX-License-Identifier: GPL-3.0-only
// Port of Seed680's MusicSaverBot behavior; see THIRD_PARTY.md.
package resona

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type telegramRateLimit struct{ wait time.Duration }

func (e telegramRateLimit) Error() string { return "Telegram 请求过于频繁，等待后重试" }

// Telegram errors deliberately exclude request URLs because bot tokens are in their paths.
func (p *Plugins) telegram(ctx context.Context, base, token, method string, body, result any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return errors.New("Telegram 请求编码失败")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/bot"+token+"/"+method, bytes.NewReader(data))
	if err != nil {
		return errors.New("Telegram API 地址无效")
	}
	req.Header.Set("Content-Type", "application/json")
	client := *p.client
	if method == "getFile" {
		client.Timeout = 30 * time.Minute
	}
	resp, err := client.Do(req)
	if err != nil {
		return errors.New("无法连接 Telegram API，请检查网络与 API 地址")
	}
	defer resp.Body.Close()
	var envelope struct {
		OK         bool            `json:"ok"`
		Result     json.RawMessage `json:"result"`
		Parameters struct {
			RetryAfter int `json:"retry_after"`
		} `json:"parameters"`
	}
	err = json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&envelope)
	if resp.StatusCode != 200 || err != nil || !envelope.OK {
		if resp.StatusCode == 429 && envelope.Parameters.RetryAfter > 0 {
			return telegramRateLimit{wait: time.Duration(min(envelope.Parameters.RetryAfter, 3600)) * time.Second}
		}
		if resp.StatusCode == 409 {
			return errors.New("Telegram 轮询冲突，请停用使用相同 Token 的其他机器人或 Webhook")
		}
		return fmt.Errorf("Telegram 请求失败（HTTP %d），请核对凭据与服务状态", resp.StatusCode)
	}
	if result != nil && json.Unmarshal(envelope.Result, result) != nil {
		return errors.New("Telegram 返回数据无效")
	}
	return nil
}

type telegramFile struct {
	ID        string        `json:"file_id"`
	Name      string        `json:"file_name"`
	Path      string        `json:"file_path"`
	Size      int64         `json:"file_size"`
	Title     string        `json:"title"`
	Performer string        `json:"performer"`
	Mime      string        `json:"mime_type"`
	Thumbnail *telegramFile `json:"thumbnail"`
}

type telegramMessage struct {
	ID   int64 `json:"message_id"`
	From struct {
		ID int64 `json:"id"`
	} `json:"from"`
	Chat struct {
		ID int64 `json:"id"`
	} `json:"chat"`
	Caption  string        `json:"caption"`
	Audio    *telegramFile `json:"audio"`
	Voice    *telegramFile `json:"voice"`
	Document *telegramFile `json:"document"`
}

func (p *Plugins) botBase(settings PluginSettings) string {
	if settings.Music.APIURL == "local" {
		return fmt.Sprintf("http://127.0.0.1:%d", settings.Telegram.Port)
	}
	if settings.Music.APIURL != "" {
		return settings.Music.APIURL
	}
	return "https://api.telegram.org"
}

func (p *Plugins) runBot(ctx context.Context, settings PluginSettings) {
	base, token := p.botBase(settings), settings.Music.Token
	offset := settings.Offset
	pending := true
	for ctx.Err() == nil {
		if pending {
			_, err := p.server.scanner.Start(p.server.ctx, false)
			pending = err != nil
		}
		var updates []struct {
			ID      int64            `json:"update_id"`
			Message *telegramMessage `json:"message"`
		}
		err := p.telegram(ctx, base, token, "getUpdates", map[string]any{
			"offset": offset, "timeout": 25, "limit": 10, "allowed_updates": []string{"message"},
		}, &updates)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			p.setStatus("musicsaverbot", "error", err.Error()+"；将自动重试")
			wait := 5 * time.Second
			var limited telegramRateLimit
			if errors.As(err, &limited) {
				wait = limited.wait
			}
			if !pausePlugin(ctx, wait) {
				return
			}
			continue
		}
		p.setStatus("musicsaverbot", "running", "正在接收 Telegram 音乐")
		for _, update := range updates {
			if ctx.Err() != nil {
				return
			}
			// Do not advance the durable offset until a complete file is published.
			name, accepted, saveErr := p.receive(ctx, settings, update.Message)
			if saveErr != nil {
				p.setStatus("musicsaverbot", "error", saveErr.Error()+"；将重试此条消息")
				pausePlugin(ctx, 5*time.Second)
				break
			}
			next := update.ID + 1
			if err := p.server.store.savePluginOffset(token, next); err != nil {
				p.setStatus("musicsaverbot", "error", "无法保存接收进度，将重试")
				pausePlugin(ctx, 5*time.Second)
				break
			}
			offset = next
			if accepted {
				pending = true
				p.mu.Lock()
				status := p.status["musicsaverbot"]
				status.LastSaved = name
				p.status["musicsaverbot"] = status
				p.mu.Unlock()
				p.server.logger.With("category", "plugin").Info("Telegram 音乐文件已保存", "file", name)
				// A reply failure must not re-download a successfully saved file.
				_ = p.telegram(ctx, base, token, "sendMessage", map[string]any{
					"chat_id": update.Message.Chat.ID, "text": "已保存：" + name + "\n已加入 Resona 整理队列。",
				}, nil)
			}
		}
	}
}

var albumCaption = regexp.MustCompile(`(?m)专辑[：:][ \t]*([^\r\n]+)`)

func telegramUserAllowed(whitelist string, user int64) bool {
	list := strings.Fields(whitelist)
	if len(list) == 0 {
		return true
	}
	for _, id := range list {
		if id == strconv.FormatInt(user, 10) {
			return true
		}
	}
	return false
}

func (p *Plugins) receive(ctx context.Context, settings PluginSettings, message *telegramMessage) (string, bool, error) {
	if message == nil {
		return "", false, nil
	}
	if !telegramUserAllowed(settings.Music.Whitelist, message.From.ID) {
		return "", false, nil
	}
	file := message.Audio
	if file == nil {
		file = message.Voice
	}
	if file == nil {
		file = message.Document
	}
	if file == nil || file.ID == "" {
		return "", false, nil
	}
	name := filepath.Base(strings.ReplaceAll(file.Name, "\\", "/"))
	if message.Voice != nil {
		name = "voice-" + safeComponent(file.ID) + ".ogg"
	}
	ext := strings.ToLower(filepath.Ext(name))
	if message.Audio != nil && !supported(name) {
		ext = map[string]string{"audio/mpeg": ".mp3", "audio/flac": ".flac", "audio/x-flac": ".flac",
			"audio/mp4": ".m4a", "audio/ogg": ".ogg", "audio/aac": ".aac", "audio/wav": ".wav"}[file.Mime]
		if ext != "" {
			name = safeComponent(file.ID) + ext
		}
	}
	lyrics := ext == ".lrc" || ext == ".txt"
	if !supported(name) && !lyrics {
		return "", false, nil
	}
	root := p.server.store.pluginInbox(p.server.config)
	dir := root
	if message.Audio != nil {
		artist, album := file.Performer, "Unknown Album"
		if artist == "" {
			artist = "Unknown Artist"
		}
		if match := albumCaption.FindStringSubmatch(message.Caption); len(match) > 1 {
			album = match[1]
		}
		dir = filepath.Join(root, safeComponent(artist), safeComponent(album))
		if file.Title != "" {
			name = safeComponent(file.Title+"-"+artist) + ext
		}
	}
	if lyrics {
		name = safeComponent(strings.TrimSuffix(name, ext)) + ".lrc"
		// A lyric may arrive after the audio has already been imported.
		var matches []Track
		stem := strings.TrimSuffix(name, ".lrc")
		for _, track := range p.server.store.Tracks() {
			if track.Library == "cloud" {
				continue
			}
			if strings.EqualFold(stem, safeComponent(track.Title+"-"+track.Artist)) {
				if t, ok := p.server.store.Track(track.ID); ok {
					matches = append(matches, t)
				}
			}
		}
		if len(matches) == 1 {
			dir = filepath.Dir(matches[0].Path)
			name = strings.TrimSuffix(filepath.Base(matches[0].Path), filepath.Ext(matches[0].Path)) + ".lrc"
			root = p.server.config.LibraryDir
		} else if len(matches) == 0 {
			var directories []string
			_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
				if err == nil && entry.Type().IsRegular() && supported(path) &&
					strings.EqualFold(stem, strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name()))) {
					directories = append(directories, filepath.Dir(path))
				}
				return nil
			})
			if len(directories) == 1 {
				dir = directories[0]
			}
		}
	}
	maxBytes := int64(2 << 30)
	if lyrics {
		maxBytes = maxLyricsSize
	}
	if file.Size < 0 || file.Size > maxBytes {
		p.setStatus("musicsaverbot", "error", "已跳过超过大小限制的文件")
		return "", false, nil
	}
	// Cover sidecars are ready before the audio becomes visible to the scanner.
	if file.Thumbnail != nil && !lyrics {
		if _, err := p.saveTelegramFile(ctx, settings, file.Thumbnail, root, dir, "cover.jpg", 5<<20); err != nil {
			p.setStatus("musicsaverbot", "running", "封面下载失败，继续保存音频")
		}
	}
	saved, err := p.saveTelegramFile(ctx, settings, file, root, dir, name, maxBytes)
	return saved, err == nil, err
}

func (p *Plugins) saveTelegramFile(ctx context.Context, settings PluginSettings, file *telegramFile, root, dir, name string, limit int64) (string, error) {
	if file.Size < 0 || file.Size > limit {
		return "", errors.New("Telegram 文件超过允许大小（音频 2 GiB，歌词 1 MiB，封面 5 MiB）")
	}
	real, err := musicDirectory(root, dir)
	if err != nil || !within(root, real) {
		return "", errors.New("音乐保存目录越界")
	}
	var remote telegramFile
	if err := p.telegram(ctx, p.botBase(settings), settings.Music.Token, "getFile", map[string]string{"file_id": file.ID}, &remote); err != nil {
		return "", err
	}
	var reader io.ReadCloser
	if filepath.IsAbs(remote.Path) {
		// Only the managed local service may return filesystem paths.
		resolved, err := filepath.EvalSymlinks(remote.Path)
		if settings.Music.APIURL != "local" || err != nil || !within(filepath.Join(p.localDir(), "files"), resolved) {
			return "", errors.New("本地 API 返回的文件不在受管缓存目录中")
		}
		f, err := os.Open(resolved)
		if err != nil {
			return "", errors.New("无法读取本地 API 缓存")
		}
		info, err := f.Stat()
		if err != nil || !info.Mode().IsRegular() || info.Size() > limit {
			f.Close()
			return "", errors.New("本地 API 缓存文件无效或过大")
		}
		reader = f
	} else {
		if remote.Path == "" || strings.ContainsAny(remote.Path, "?#\\") {
			return "", errors.New("Telegram 文件路径无效")
		}
		segments := strings.Split(remote.Path, "/")
		for _, segment := range segments {
			if segment == ".." || segment == "." || segment == "" {
				return "", errors.New("Telegram 文件路径无效")
			}
		}
		for i := range segments {
			segments[i] = url.PathEscape(segments[i])
		}
		target := p.botBase(settings) + "/file/bot" + settings.Music.Token + "/" + strings.Join(segments, "/")
		downloadCtx, cancel := context.WithTimeout(ctx, 30*time.Minute)
		defer cancel()
		req, err := http.NewRequestWithContext(downloadCtx, http.MethodGet, target, nil)
		if err != nil {
			return "", errors.New("Telegram 文件地址无效")
		}
		// Large downloads use their own deadline, rather than the polling timeout.
		client := *p.client
		client.Timeout = 0
		resp, err := client.Do(req)
		if err != nil {
			return "", errors.New("Telegram 文件下载失败")
		}
		reader = resp.Body
		if resp.StatusCode != 200 || resp.ContentLength > limit {
			reader.Close()
			return "", errors.New("Telegram 文件下载失败或文件过大")
		}
	}
	defer reader.Close()
	out, err := os.CreateTemp(real, ".telegram-*")
	if err != nil {
		return "", errors.New("无法创建下载临时文件")
	}
	defer os.Remove(out.Name())
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(out, hash), io.LimitReader(&contextReader{ctx: ctx, r: reader}, limit+1))
	if err == nil && (n == 0 || n > limit || (file.Size > 0 && n != file.Size) || (remote.Size > 0 && n != remote.Size)) {
		err = errors.New("Telegram 文件下载不完整或大小不符")
	}
	if err == nil {
		err = out.Chmod(0777)
	}
	if err == nil {
		err = out.Sync()
	}
	closeErr := out.Close()
	if err != nil || closeErr != nil {
		return "", errors.New("文件下载失败或无法保存完整文件")
	}
	ext := strings.ToLower(filepath.Ext(name))
	stem := safeComponent(strings.TrimSuffix(name, filepath.Ext(name)))
	sum := hex.EncodeToString(hash.Sum(nil))
	for _, suffix := range []string{"", " [" + sum[:12] + "]"} {
		dest := filepath.Join(real, stem+suffix+ext)
		if err := os.Link(out.Name(), dest); err == nil {
			return filepath.Base(dest), nil
		} else if !errors.Is(err, os.ErrExist) {
			return "", errors.New("无法保存下载文件")
		}
		if info, err := os.Lstat(dest); err == nil && info.Mode().IsRegular() {
			if old, _, err := hashFile(ctx, dest); err == nil && old == sum {
				return filepath.Base(dest), os.Chmod(dest, 0777)
			}
		}
	}
	return "", errors.New("存在同名不同内容文件，未覆盖")
}
