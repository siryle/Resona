package resona

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

type managedRoot struct {
	ID, Name, Path string
}

func (s *Server) managedRoots() []managedRoot {
	return []managedRoot{{"filesystem", "服务器文件系统", "/"}, {"library", "音乐库", s.config.LibraryDir},
		{"inbox", "导入目录", s.config.InboxDir}, {"plugins", "插件收件目录", s.store.pluginInbox(s.config)},
		{"strm", "STRM 目录", filepath.Join(s.config.DataDir, "cloud115", "strm")}}
}

func (s *Server) fileRoot(id string) (*os.Root, string, error) {
	for _, item := range s.managedRoots() {
		if item.ID == id {
			if id == "plugins" || id == "strm" {
				if _, err := musicDirectory(item.Path, item.Path); err != nil {
					return nil, "", err
				}
			}
			root, err := os.OpenRoot("/")
			return root, "/", err
		}
	}
	return nil, "", errors.New("未知的管理目录")
}

func managedPath(value string) (string, error) {
	if strings.ContainsRune(value, 0) {
		return "", errors.New("文件路径包含无效字符")
	}
	return strings.TrimPrefix(filepath.Clean("/"+value), "/"), nil
}

func (s *Server) managedLocation(id, value string) (string, error) {
	for _, item := range s.managedRoots() {
		if item.ID != id {
			continue
		}
		if !filepath.IsAbs(value) {
			value = filepath.Join(item.Path, value)
		}
		path, err := managedPath(value)
		if err != nil {
			return "", err
		}
		// Resolve parent links for normal Unix filesystem navigation; the final link remains an entry.
		parent, err := filepath.EvalSymlinks(filepath.Dir("/" + path))
		if err != nil {
			return "", err
		}
		return managedPath(filepath.Join(parent, filepath.Base(path)))
	}
	return "", errors.New("未知的管理目录")
}

func checkManagedPath(root *os.Root, path string) (fs.FileInfo, error) {
	if path == "" {
		path = "."
	}
	info, err := root.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() && !info.Mode().IsRegular() && info.Mode()&os.ModeSymlink == 0 {
		return nil, errors.New("不支持操作设备、套接字或其他特殊文件")
	}
	return info, nil
}

type fileEntry struct {
	Name     string    `json:"name"`
	Path     string    `json:"path"`
	Type     string    `json:"type"`
	Size     int64     `json:"size"`
	Modified time.Time `json:"modified"`
	Blocked  bool      `json:"blocked"`
}

func (s *Server) files(w http.ResponseWriter, r *http.Request) {
	root, _, err := s.fileRoot(r.URL.Query().Get("root"))
	if err != nil {
		apiError(w, 400, "管理目录不可用")
		return
	}
	defer root.Close()
	path, err := s.managedLocation(r.URL.Query().Get("root"), r.URL.Query().Get("path"))
	if err == nil {
		real, resolveErr := filepath.EvalSymlinks("/" + path)
		err = resolveErr
		if err == nil {
			path, _ = managedPath(real)
		}
	}
	if err != nil {
		apiError(w, 400, err.Error())
		return
	}
	info, err := checkManagedPath(root, path)
	if err != nil || !info.IsDir() {
		apiError(w, 404, "目录不存在或无法访问")
		return
	}
	if path == "" {
		path = "."
	}
	dir, err := root.Open(path)
	if err != nil {
		apiError(w, 403, "无法读取目录")
		return
	}
	defer dir.Close()
	entries, err := dir.ReadDir(-1)
	if err != nil {
		apiError(w, 500, "读取目录失败")
		return
	}
	items := []fileEntry{}
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			continue
		}
		kind := strings.TrimPrefix(strings.ToUpper(filepath.Ext(entry.Name())), ".")
		blocked := !info.IsDir() && !info.Mode().IsRegular() && info.Mode()&os.ModeSymlink == 0
		if info.Mode()&os.ModeSymlink != 0 {
			if followed, err := os.Stat(filepath.Join("/", path, entry.Name())); err == nil && followed.IsDir() {
				info = followed
			} else {
				kind = "符号链接"
			}
		}
		if info.IsDir() {
			kind = "文件夹"
		} else if blocked {
			kind = "链接或特殊文件"
		} else if kind == "" {
			kind = "文件"
		}
		items = append(items, fileEntry{entry.Name(), filepath.ToSlash(filepath.Join("/", path, entry.Name())), kind, info.Size(), info.ModTime(), blocked})
	}
	sort.Slice(items, func(i, j int) bool {
		if (items[i].Type == "文件夹") != (items[j].Type == "文件夹") {
			return items[i].Type == "文件夹"
		}
		return items[i].Name < items[j].Name
	})
	jsonResponse(w, 200, map[string]any{"items": items, "path": filepath.ToSlash(filepath.Join("/", path))})
}

type fileOperation struct {
	Action     string   `json:"action"`
	Root       string   `json:"root"`
	Paths      []string `json:"paths"`
	TargetRoot string   `json:"target_root"`
	Target     string   `json:"target"`
}

type pendingFileOperation struct {
	Action, Root, Path, TargetRoot, Destination, Hidden string
	Tracks                                              map[string]DiskTrack
	CloudItems                                          map[string]CloudItem
	ProbeQueue                                          []string
}

func (s *Server) fileJournal() string { return filepath.Join(s.config.DataDir, "file-operation.json") }

// An interrupted mutation is rolled back before serving the library again.
func (s *Server) recoverFileOperation() error {
	data, err := os.ReadFile(s.fileJournal())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var pending pendingFileOperation
	if err := json.Unmarshal(data, &pending); err != nil {
		return fmt.Errorf("read file operation recovery: %w", err)
	}
	source, _, err := s.fileRoot(pending.Root)
	if err != nil {
		return err
	}
	defer source.Close()
	next := pending.Hidden
	_, originalErr := source.Lstat(pending.Path)
	_, stagedErr := source.Lstat(next)
	if originalErr == nil && stagedErr == nil {
		return errors.New("file operation recovery conflict; both original and staged entries exist")
	}
	if errors.Is(originalErr, os.ErrNotExist) && stagedErr == nil {
		if err := source.Rename(next, pending.Path); err != nil {
			return err
		}
	} else if originalErr != nil {
		return errors.New("file operation recovery: original entry unavailable")
	}
	if pending.Action != "delete" && pending.Hidden != pending.Destination {
		target, _, err := s.fileRoot(pending.TargetRoot)
		if err != nil {
			return err
		}
		err = target.RemoveAll(pending.Destination)
		target.Close()
		if err != nil {
			return err
		}
	}
	if err := s.store.update(func(st *libraryState) error {
		for id, disk := range pending.Tracks {
			st.Tracks[id] = disk
		}
		for id, item := range pending.CloudItems {
			st.Cloud.Items[id] = item
		}
		queued := make(map[string]bool)
		var queue []string
		for _, id := range append(pending.ProbeQueue, st.Cloud.ProbeQueue...) {
			if _, ok := st.Cloud.Items[id]; ok && !queued[id] {
				queued[id] = true
				queue = append(queue, id)
			}
		}
		st.Cloud.ProbeQueue = queue
		return nil
	}); err != nil {
		return err
	}
	s.logger.Warn("已恢复服务中断前未完成的文件操作", "action", pending.Action)
	return os.Remove(s.fileJournal())
}

func (s *Server) operateFiles(w http.ResponseWriter, r *http.Request) {
	var body fileOperation
	if !decodeBody(w, r, &body) {
		return
	}
	if (body.Action != "copy" && body.Action != "move" && body.Action != "rename" && body.Action != "delete") || len(body.Paths) == 0 || len(body.Paths) > 100 ||
		(body.Action == "rename" && len(body.Paths) != 1) {
		apiError(w, 400, "请选择 1 到 100 项及有效的操作")
		return
	}
	s.scanner.mu.Lock()
	if s.scanner.active || s.scanner.editing {
		s.scanner.mu.Unlock()
		apiError(w, 409, errLibraryBusy.Error())
		return
	}
	s.scanner.editing = true
	s.scanner.mu.Unlock()
	defer func() { s.scanner.mu.Lock(); s.scanner.editing = false; s.scanner.mu.Unlock() }()
	if _, err := os.Stat(s.fileJournal()); err == nil {
		apiError(w, 409, "上次文件操作尚未恢复，请重启服务完成恢复后重试")
		return
	} else if !errors.Is(err, os.ErrNotExist) {
		apiError(w, 500, "无法读取文件恢复状态")
		return
	}
	source, sourceDir, err := s.fileRoot(body.Root)
	if err != nil {
		apiError(w, 400, "来源目录不可用")
		return
	}
	defer source.Close()
	var target *os.Root
	var targetDir, targetPath string
	if body.Action != "delete" {
		if body.TargetRoot == "" {
			body.TargetRoot = body.Root
		}
		target, targetDir, err = s.fileRoot(body.TargetRoot)
		if err != nil {
			apiError(w, 400, "目标目录不可用")
			return
		}
		defer target.Close()
		targetPath, err = s.managedLocation(body.TargetRoot, body.Target)
		parent := targetPath
		if body.Action != "rename" && err == nil {
			real, resolveErr := filepath.EvalSymlinks("/" + parent)
			err = resolveErr
			if err == nil {
				targetPath, _ = managedPath(real)
				parent = targetPath
			}
		}
		if parent == "" {
			parent = "."
		}
		if body.Action == "rename" {
			parent = filepath.Dir(targetPath)
		}
		if err == nil {
			info, checkErr := checkManagedPath(target, parent)
			err = checkErr
			if err == nil && !info.IsDir() {
				err = errors.New("目标必须是文件夹")
			}
		}
		if err != nil {
			apiError(w, 400, "目标目录不存在或无法访问")
			return
		}
	}
	paths := make([]string, len(body.Paths))
	for i, value := range body.Paths {
		paths[i], err = s.managedLocation(body.Root, value)
		if err != nil || paths[i] == "." || paths[i] == "" {
			apiError(w, 400, "不允许对文件系统根目录执行批量修改或删除")
			return
		}
		for k := 0; k < i; k++ {
			if within(paths[k], paths[i]) || within(paths[i], paths[k]) {
				apiError(w, 400, "请选择互不包含且不重复的条目")
				return
			}
		}
	}
	completed := 0
	for _, path := range paths {
		dest := targetPath
		if body.Action != "rename" {
			dest = filepath.Join(targetPath, filepath.Base(path))
		}
		if err := s.operateFile(r.Context(), body, source, sourceDir, path, target, targetDir, dest); err != nil {
			s.logger.With("category", "system").Warn("文件操作未完成", "action", body.Action, "file", path, "error", err)
			jsonResponse(w, 409, map[string]any{"error": fmt.Sprintf("已完成 %d 项；%s：%s", completed, filepath.Base(path), err), "completed": completed})
			return
		}
		completed++
		s.logger.Info("文件操作已完成", "action", body.Action, "root", body.Root, "file", path)
	}
	jsonResponse(w, 200, map[string]int{"completed": completed})
}

func (s *Server) operateFile(ctx context.Context, body fileOperation, source *os.Root, sourceDir, path string, target *os.Root, targetDir, dest string) error {
	if !s.cloud.dataMu.TryLock() {
		return errLibraryBusy
	}
	defer s.cloud.dataMu.Unlock()
	action := body.Action
	if err := ctx.Err(); err != nil {
		return err
	}
	if _, err := checkManagedPath(source, path); err != nil {
		return err
	}
	from, to := filepath.Join(sourceDir, path), filepath.Join(targetDir, dest)
	if action != "delete" {
		if within(from, to) {
			return errors.New("不能复制或移动到自身及子目录")
		}
		if _, err := target.Lstat(dest); !errors.Is(err, os.ErrNotExist) {
			return errors.New("目标已存在，已保留原文件，请使用其他名称")
		}
	}
	sameRoot := false
	if action != "delete" {
		originalInfo, statErr := source.Lstat(path)
		parentInfo, parentErr := target.Stat(filepath.Dir(dest))
		if statErr != nil || parentErr != nil {
			return errors.New("无法读取来源或目标目录")
		}
		originalStat, okSource := originalInfo.Sys().(*syscall.Stat_t)
		parentStat, okTarget := parentInfo.Sys().(*syscall.Stat_t)
		sameRoot = sourceDir == targetDir && okSource && okTarget && originalStat.Dev == parentStat.Dev
	}
	if action == "copy" || (!sameRoot && (action == "move" || action == "rename")) {
		budget := 10000
		if err := copyManaged(ctx, source, path, target, dest, &budget); err != nil {
			return err
		}
		if err := s.destinationPermissions(to); err != nil {
			_ = target.RemoveAll(dest)
			return err
		}
		if action == "copy" {
			return nil
		}
	}
	// Keep removed entries in a hidden sibling until the index is safely published.
	hidden := filepath.Join(filepath.Dir(path), ".resona-files-"+randomID(12))
	moved := false
	err := s.store.updateWithRollback(func(st *libraryState) error {
		next := hidden
		if sameRoot && action != "delete" {
			next = dest
		}
		pending := pendingFileOperation{Action: action, Root: "filesystem", Path: path,
			TargetRoot: "filesystem", Destination: dest, Hidden: next,
			Tracks: map[string]DiskTrack{}, CloudItems: map[string]CloudItem{}}
		for id, disk := range st.Tracks {
			if within(from, disk.File) {
				pending.Tracks[id] = disk
				if item, ok := st.Cloud.Items[id]; ok {
					pending.CloudItems[id] = item
				}
			}
		}
		if len(pending.CloudItems) > 0 {
			pending.ProbeQueue = append([]string(nil), st.Cloud.ProbeQueue...)
		}
		if err := atomicJSON(s.fileJournal(), pending); err != nil {
			return err
		}
		if err := source.Rename(path, next); err != nil {
			return err
		}
		moved = true
		if sameRoot && action != "delete" {
			if err := s.destinationPermissions(to); err != nil {
				return err
			}
		}
		removed := make(map[string]bool)
		for id, disk := range st.Tracks {
			if !within(from, disk.File) {
				continue
			}
			library := s.config.LibraryDir
			if disk.Remote != nil {
				library = filepath.Join(s.config.DataDir, "cloud115", "strm")
			}
			if action == "delete" || !within(library, to) {
				delete(st.Tracks, id)
				if disk.Remote != nil {
					removed[id] = true
				}
				continue
			}
			relative, err := filepath.Rel(from, disk.File)
			if err != nil {
				return err
			}
			disk.File = filepath.Join(to, relative)
			st.Tracks[id] = disk
		}
		removeCloudTracks(st, removed)
		return nil
	}, func() error {
		var restore error
		if moved {
			next := hidden
			if sameRoot && action != "delete" {
				next = dest
			}
			restore = source.Rename(next, path)
		}
		if !sameRoot && action != "delete" {
			restore = errors.Join(restore, target.RemoveAll(dest))
		}
		if restore == nil {
			if err := os.Remove(s.fileJournal()); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
		return restore
	})
	if err != nil {
		return err
	}
	if err := os.Remove(s.fileJournal()); err != nil {
		return errors.New("文件操作已保存，但恢复记录未能清理，请检查数据目录权限")
	}
	if action == "delete" || !sameRoot {
		if err := source.RemoveAll(hidden); err != nil {
			return errors.New("索引已更新；旧文件清理未完成，请检查目录权限")
		}
	}
	return nil
}

func copyManaged(ctx context.Context, source *os.Root, path string, target *os.Root, dest string, budget *int) (err error) {
	*budget--
	if *budget < 0 {
		return errors.New("单次复制超过 10000 个文件，请分批操作")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	info, err := checkManagedPath(source, path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		link, err := source.Readlink(path)
		if err != nil {
			return err
		}
		return target.Symlink(link, dest)
	}
	created := false
	defer func() {
		if err != nil && created {
			_ = target.RemoveAll(dest)
		}
	}()
	if info.IsDir() {
		if err = target.Mkdir(dest, 0750); err != nil {
			return err
		}
		created = true
		entries, readErr := fs.ReadDir(source.FS(), path)
		if readErr != nil {
			return readErr
		}
		for _, entry := range entries {
			if err = copyManaged(ctx, source, filepath.Join(path, entry.Name()), target, filepath.Join(dest, entry.Name()), budget); err != nil {
				return err
			}
		}
		return nil
	}
	in, err := source.Open(path)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := target.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0640)
	if err != nil {
		return err
	}
	created = true
	_, err = io.Copy(out, &contextReader{ctx, in})
	if err == nil {
		err = out.Sync()
	}
	return errors.Join(err, out.Close())
}
