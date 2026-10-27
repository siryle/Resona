package resona

import (
	"context"
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

type strmWriter struct {
	cloud *Cloud115
	root  *os.Root
	dirs  map[string]bool
	base  string
}

func (c *Cloud115) newSTRMWriter() *strmWriter {
	return &strmWriter{cloud: c, dirs: map[string]bool{".": true},
		base: strings.TrimRight(c.summary().Settings.BaseURL, "/")}
}

func (w *strmWriter) close() {
	if w.root != nil {
		w.root.Close()
	}
}

func (w *strmWriter) directory(dir string) error {
	if w.dirs[dir] {
		return nil
	}
	if err := w.directory(filepath.Dir(dir)); err != nil {
		return err
	}
	if err := w.root.Mkdir(dir, 0777); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	if err := w.root.Chmod(dir, 0777); err != nil {
		return err
	}
	w.dirs[dir] = true
	return nil
}

func (w *strmWriter) write(ctx context.Context, item CloudItem, path string) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	root := filepath.Join(w.cloud.server.config.DataDir, "cloud115", "strm")
	if !within(root, path) {
		return false, errors.New("STRM path escapes cloud library")
	}
	if w.root == nil {
		if _, err := musicDirectory(root, root); err != nil {
			return false, err
		}
		var err error
		w.root, err = os.OpenRoot(root)
		if err != nil {
			return false, err
		}
	}
	name, err := filepath.Rel(root, path)
	if err != nil {
		return false, err
	}
	dir := filepath.Dir(name)
	if err := w.directory(dir); err != nil {
		return false, err
	}
	content := w.base + "/api/v1/tracks/" + item.TrackID + "/stream\n"
	info, err := w.root.Lstat(name)
	if err == nil {
		if !info.Mode().IsRegular() {
			return false, errors.New("STRM output must be a regular file")
		}
		previous, err := w.root.ReadFile(name)
		if err != nil {
			return false, err
		}
		if string(previous) == content {
			if info.Mode().Perm() != 0777 {
				return true, w.root.Chmod(name, 0777)
			}
			return true, nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	temporary := filepath.Join(dir, ".strm-"+rand.Text())
	file, err := w.root.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0777)
	if err != nil {
		return false, err
	}
	defer w.root.Remove(temporary)
	_, err = file.WriteString(content)
	if err == nil {
		err = file.Chmod(0777)
	}
	// STRMs are reproducible pointers; atomically replace them without an fsync per song.
	err = errors.Join(err, file.Close(), ctx.Err())
	if err != nil {
		return false, err
	}
	if err := w.root.Rename(temporary, name); err != nil {
		return false, err
	}
	return false, nil
}

func (c *Cloud115) writeSTRM(item CloudItem) error {
	writer := c.newSTRMWriter()
	defer writer.close()
	_, err := writer.write(c.server.ctx, item, c.strmPath(item))
	return err
}
