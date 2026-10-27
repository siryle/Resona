package resona

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maxLogEntries = 2000
const maxLogFileSize = 2 << 20

type LogEntry struct {
	Time     time.Time `json:"time"`
	Level    string    `json:"level"`
	Category string    `json:"category"`
	Message  string    `json:"message"`
}

type LogBook struct {
	mu      sync.Mutex
	path    string
	entries []LogEntry
	secrets []string
}

var logCredentials = regexp.MustCompile(`(?i)(password|token|api_hash|authorization|cookie|session|secret|accesskey)([=: ]+)[^\s&,;]+`)
var logBotToken = regexp.MustCompile(`[0-9]{5,}:[A-Za-z0-9_-]{20,}`)
var logURL = regexp.MustCompile(`https?://[^\s"<>]+`)

func openLogBook(dir string) (*LogBook, error) {
	book := &LogBook{path: filepath.Join(dir, "runtime.log"), entries: []LogEntry{}}
	for _, path := range []string{book.path + ".1", book.path} {
		f, err := os.Open(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 4096), 32<<10)
		for scanner.Scan() {
			var entry LogEntry
			if json.Unmarshal(scanner.Bytes(), &entry) == nil && validLogLevel(entry.Level) && validLogCategory(entry.Category) {
				book.entries = append(book.entries, entry)
			}
		}
		err = scanner.Err()
		f.Close()
		if err != nil {
			return nil, err
		}
	}
	book.trim()
	return book, nil
}

func (b *LogBook) trim() {
	if len(b.entries) > maxLogEntries {
		b.entries = append([]LogEntry{}, b.entries[len(b.entries)-maxLogEntries:]...)
	}
}

func (b *LogBook) registerSecrets(settings PluginSettings) {
	b.mu.Lock()
	defer b.mu.Unlock()
	// Keep old credentials redacted after rotation as well.
	for _, secret := range []string{settings.Music.Token, settings.Telegram.APIHash, settings.Telegram.ProxyPassword} {
		if secret != "" && !slices.Contains(b.secrets, secret) {
			b.secrets = append(b.secrets, secret)
		}
	}
}

func (b *LogBook) sanitize(text string) string {
	for _, secret := range b.secrets {
		text = strings.ReplaceAll(text, secret, "[redacted]")
	}
	text = logURL.ReplaceAllStringFunc(text, func(value string) string {
		// Provider URLs may contain Bot tokens, signatures or search queries.
		if i := strings.Index(value, "?"); i >= 0 {
			value = value[:i] + "?[redacted]"
		}
		if i := strings.Index(value, "@"); i >= 0 {
			if scheme := strings.Index(value, "://"); scheme >= 0 {
				value = value[:scheme+3] + "[redacted]@" + value[i+1:]
			}
		}
		return value
	})
	text = logBotToken.ReplaceAllString(text, "[redacted]")
	text = logCredentials.ReplaceAllString(text, "$1$2[redacted]")
	text = strings.NewReplacer("\r", " ", "\n", " ", "\x00", "").Replace(text)
	if len(text) > 4096 {
		text = string([]rune(text)[:min(len([]rune(text)), 1024)]) + "…"
	}
	return text
}

func (b *LogBook) append(entry LogEntry) (LogEntry, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	entry.Message = b.sanitize(entry.Message)
	b.entries = append(b.entries, entry)
	b.trim()
	if info, err := os.Stat(b.path); err == nil && info.Size() >= maxLogFileSize {
		if err := os.Rename(b.path, b.path+".1"); err != nil {
			return entry, err
		}
	}
	f, err := os.OpenFile(b.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return entry, err
	}
	err = json.NewEncoder(f).Encode(entry)
	return entry, errors.Join(err, f.Close())
}

func (b *LogBook) clear() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, path := range []string{b.path + ".1", b.path} {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	b.entries = []LogEntry{}
	return nil
}

type logHandler struct {
	book    *LogBook
	console slog.Handler
	attrs   []slog.Attr
	group   string
}

func (h *logHandler) Enabled(context.Context, slog.Level) bool { return true }
func (h *logHandler) Handle(ctx context.Context, record slog.Record) error {
	category, parts := "system", []string{record.Message}
	add := func(attr slog.Attr) {
		if attr.Key == "category" {
			category = attr.Value.String()
		} else if logCredentials.MatchString(attr.Key + "=value") {
			parts = append(parts, attr.Key+"=[redacted]")
		} else if attr.Key != "" {
			parts = append(parts, h.group+attr.Key+"="+fmt.Sprint(attr.Value.Resolve().Any()))
		}
	}
	for _, attr := range h.attrs {
		add(attr)
	}
	record.Attrs(func(attr slog.Attr) bool { add(attr); return true })
	if !validLogCategory(category) {
		category = "system"
	}
	level := "INFO"
	switch {
	case record.Level >= slog.LevelError:
		level = "ERROR"
	case record.Level >= slog.LevelWarn:
		level = "WARN"
	case record.Level < slog.LevelInfo:
		level = "DEBUG"
	}
	entry, err := h.book.append(LogEntry{record.Time.UTC(), level, category, strings.Join(parts, " ")})
	clean := slog.NewRecord(record.Time, record.Level, entry.Message, record.PC)
	clean.AddAttrs(slog.String("category", category))
	if h.console.Enabled(ctx, record.Level) {
		_ = h.console.Handle(ctx, clean)
	}
	if err != nil {
		failure := slog.NewRecord(time.Now(), slog.LevelError, "Unable to persist runtime log", 0)
		_ = h.console.Handle(ctx, failure)
	}
	return nil
}
func (h *logHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	copy := *h
	copy.attrs = append(append([]slog.Attr{}, h.attrs...), attrs...)
	return &copy
}
func (h *logHandler) WithGroup(name string) slog.Handler {
	copy := *h
	copy.group += name + "."
	return &copy
}

func validLogLevel(level string) bool {
	return slices.Contains([]string{"DEBUG", "INFO", "WARN", "ERROR"}, level)
}
func validLogCategory(category string) bool {
	return slices.Contains([]string{"system", "scan", "plugin", "settings", "strm", "probe", "playback"}, category)
}

func (s *Server) Logger() *slog.Logger { return s.logger }

func (s *Server) logs(w http.ResponseWriter, r *http.Request) {
	level, category, search := strings.ToUpper(r.URL.Query().Get("level")), r.URL.Query().Get("category"), r.URL.Query().Get("search")
	limit := 2000
	if raw := r.URL.Query().Get("limit"); raw != "" {
		var err error
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 1 || limit > maxLogEntries {
			apiError(w, 400, "日志数量必须在 1 到 2000 之间")
			return
		}
	}
	if (level != "" && !validLogLevel(level)) || (category != "" && !validLogCategory(category)) || len(search) > 512 {
		apiError(w, 400, "日志筛选条件无效")
		return
	}
	search = strings.ToLower(search)
	items := []LogEntry{}
	counts := map[string]int{"DEBUG": 0, "INFO": 0, "WARN": 0, "ERROR": 0}
	s.logbook.mu.Lock()
	retained := len(s.logbook.entries)
	for i := retained - 1; i >= 0; i-- {
		entry := s.logbook.entries[i]
		entry.Message = s.logbook.sanitize(entry.Message)
		if (category != "" && entry.Category != category) || !strings.Contains(strings.ToLower(entry.Message), search) {
			continue
		}
		counts[entry.Level]++
		if (level == "" || entry.Level == level) && len(items) < limit {
			items = append(items, entry)
		}
	}
	s.logbook.mu.Unlock()
	jsonResponse(w, 200, map[string]any{"items": items, "counts": counts, "retained": retained, "capacity": maxLogEntries})
}

func (s *Server) clearLogs(w http.ResponseWriter, r *http.Request) {
	if err := s.logbook.clear(); err != nil {
		apiError(w, 500, "无法清空日志，请检查数据目录权限")
		return
	}
	s.logger.Info("日志已由管理员清空")
	w.WriteHeader(http.StatusNoContent)
}
