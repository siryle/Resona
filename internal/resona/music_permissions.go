package resona

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

func musicDirectory(root, dir string) (string, error) {
	if !within(root, dir) {
		return "", errors.New("destination escapes music directory")
	}
	if err := os.MkdirAll(root, 0750); err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(root)
	if err != nil || resolved != root {
		return "", errors.New("music root must be a resolved directory")
	}
	// chmod explicitly because mkdir permissions are filtered by the process umask.
	if err := os.Chmod(root, 0777); err != nil {
		return "", err
	}
	relative, _ := filepath.Rel(root, dir)
	for _, component := range strings.Split(relative, string(filepath.Separator)) {
		if component == "." {
			continue
		}
		next := filepath.Join(resolved, component)
		if err := os.Mkdir(next, 0777); err != nil && !errors.Is(err, os.ErrExist) {
			return "", err
		}
		next, err = filepath.EvalSymlinks(next)
		if err != nil || !within(root, next) {
			return "", errors.New("destination escapes music directory")
		}
		if err := os.Chmod(next, 0777); err != nil {
			return "", err
		}
		resolved = next
	}
	return resolved, nil
}

func musicPermissions(root, path string) error {
	if !within(root, path) {
		return nil
	}
	parent := filepath.Dir(path)
	if path == root {
		parent = root
	}
	if _, err := musicDirectory(root, parent); err != nil {
		return err
	}
	return filepath.WalkDir(path, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		return os.Chmod(path, 0777)
	})
}

func (s *Server) destinationPermissions(path string) error {
	for _, root := range []string{s.config.LibraryDir, s.config.InboxDir, s.store.pluginInbox(s.config)} {
		if err := musicPermissions(root, path); err != nil {
			return err
		}
	}
	return nil
}
