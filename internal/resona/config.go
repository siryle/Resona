package resona

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

type Config struct {
	Addr, DataDir, InboxDir, LibraryDir string
	Username                            string
	CookieSecure, Scrape                bool
	ScanInterval                        time.Duration
}

func ConfigFromEnv() (Config, error) {
	c := Config{
		Addr: env("LISTEN_ADDR", ":8080"), DataDir: env("DATA_PATH", "./data"),
		InboxDir: env("INBOX_PATH", "./music/inbox"), LibraryDir: env("LIBRARY_PATH", "./music/library"),
		Username: env("ADMIN_USER", "admin"),
	}
	var err error
	if c.CookieSecure, err = strconv.ParseBool(env("COOKIE_SECURE", "false")); err != nil {
		return c, errors.New("COOKIE_SECURE must be true or false")
	}
	if c.Scrape, err = strconv.ParseBool(env("SCRAPE_ENABLED", "true")); err != nil {
		return c, errors.New("SCRAPE_ENABLED must be true or false")
	}
	c.ScanInterval, err = time.ParseDuration(env("SCAN_INTERVAL", "15m"))
	if err != nil || c.ScanInterval < 0 || (c.ScanInterval > 0 && c.ScanInterval < time.Minute) {
		return c, errors.New("SCAN_INTERVAL must be 0 or a duration of at least 1m")
	}
	if len(c.Username) == 0 || len(c.Username) > 128 {
		return c, errors.New("ADMIN_USER must contain 1 to 128 bytes")
	}
	for _, p := range []*string{&c.DataDir, &c.InboxDir, &c.LibraryDir} {
		*p, err = filepath.Abs(*p)
		if err != nil {
			return c, err
		}
		if err = os.MkdirAll(*p, 0750); err != nil {
			return c, err
		}
		*p, err = filepath.EvalSymlinks(*p)
		if err != nil {
			return c, err
		}
	}
	dirs := []string{c.DataDir, c.InboxDir, c.LibraryDir}
	for i, a := range dirs {
		for j, b := range dirs {
			if i != j && within(a, b) {
				return c, errors.New("DATA_PATH, INBOX_PATH and LIBRARY_PATH must be separate, non-nested directories")
			}
		}
	}
	if _, err := musicDirectory(c.LibraryDir, c.LibraryDir); err != nil {
		return c, err
	}
	return c, nil
}

func within(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !filepath.IsAbs(rel) && (len(rel) < 3 || rel[:3] != ".."+string(filepath.Separator))
}

func env(key, fallback string) string {
	if s := os.Getenv(key); s != "" {
		return s
	}
	return fallback
}
