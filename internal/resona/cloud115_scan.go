package resona

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func (c *Cloud115) scanLocal(w http.ResponseWriter, r *http.Request) {
	var body struct{}
	if !decodeBody(w, r, &body) {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.busyLocked() {
		apiError(w, 409, "115 任务正在运行，请完成后再扫描本地 STRM")
		return
	}
	if c.server.ctx.Err() != nil {
		apiError(w, 503, "服务正在停止")
		return
	}
	job := Job{ID: randomID(12), Library: "cloud", State: "running", Phase: "扫描本地 STRM",
		StartedAt: time.Now().UTC(), Errors: []string{}}
	if err := c.server.store.putJob(job); err != nil {
		apiError(w, 500, "无法保存扫描任务")
		return
	}
	c.fileBusy = true
	c.wg.Add(1)
	go func(job Job) {
		defer c.wg.Done()
		defer func() {
			c.mu.Lock()
			c.fileBusy = false
			c.mu.Unlock()
		}()
		logger := c.server.logger.With("category", "strm")
		logger.Info("开始扫描本地 STRM", "job", job.ID)
		if err := c.scanSTRMs(c.server.ctx, &job); err != nil {
			job.State, job.Phase = "failed", "本地 STRM 扫描失败，原索引已保留"
			job.Errors = append(job.Errors, err.Error())
		} else {
			job.State, job.Phase = "completed", "本地 STRM 扫描完成，网盘音乐库已刷新"
		}
		job.EndedAt = time.Now().UTC()
		if err := c.server.store.putJob(job); err != nil {
			logger.Error("保存 STRM 扫描任务失败", "error", err)
		}
		logger.Info(job.Phase, "job", job.ID, "processed", job.Processed, "indexed", job.Imported, "skipped", job.Skipped)
	}(job)
	jsonResponse(w, 202, job)
}

func (c *Cloud115) scanSTRMs(ctx context.Context, job *Job) error {
	c.dataMu.Lock()
	defer c.dataMu.Unlock()
	base := filepath.Join(c.server.config.DataDir, "cloud115", "strm")
	state := c.snapshot()
	paths := make(map[string]string)
	root, err := os.OpenRoot(base)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err == nil {
		defer root.Close()
		err = fs.WalkDir(root.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if err := ctx.Err(); err != nil {
				return err
			}
			if entry.IsDir() || !strings.EqualFold(filepath.Ext(name), ".strm") {
				return nil
			}
			job.Processed++
			if job.Processed > cloudMaxFiles {
				return errors.New("本地 STRM 数量超过扫描上限")
			}
			job.Skipped++
			if !entry.Type().IsRegular() {
				return nil
			}
			f, err := root.Open(name)
			if err != nil {
				return err
			}
			data, err := io.ReadAll(io.LimitReader(f, 8193))
			err = errors.Join(err, f.Close())
			if err != nil {
				return err
			}
			if len(data) > 8192 {
				return nil
			}
			u, err := url.Parse(strings.TrimSpace(string(data)))
			if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" ||
				u.User != nil || u.RawQuery != "" || u.Fragment != "" {
				return nil
			}
			before, found := strings.CutSuffix(u.Path, "/stream")
			if !found || len(before) < 64 {
				return nil
			}
			id := before[len(before)-64:]
			if !validHex(id, 64) || !strings.HasSuffix(before[:len(before)-64], "/api/v1/tracks/") {
				return nil
			}
			item, ok := state.Items[id]
			if !ok || item.Account != state.Account || item.State == "missing" || item.State == "skipped" {
				return nil
			}
			path := filepath.Join(base, filepath.FromSlash(name))
			if previous := paths[id]; previous != "" {
				if track, ok := c.server.store.Track(id); !ok || track.Path != path {
					return nil
				}
			}
			paths[id] = path
			return nil
		})
		if err != nil {
			return err
		}
	}
	job.Skipped = job.Processed - len(paths)
	return c.server.store.updateCloud(func(st *libraryState) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		missing := make(map[string]bool)
		for id, disk := range st.Tracks {
			if disk.Remote != nil && paths[id] == "" && c.missingSTRM(disk.File) {
				missing[id] = true
			}
		}
		removeCloudTracks(st, missing)
		for id, path := range paths {
			item := st.Cloud.Items[id]
			disk := cloudSTRMTrack(item, st.Tracks[id], path, st.Cloud.Cookie == "" || !st.Cloud.Settings.Enabled)
			st.Tracks[id] = disk
			job.Imported++
			job.Items = append(job.Items, JobItem{TrackID: id, Filename: filepath.Base(path),
				Title: disk.Title, Artist: disk.Artist, Album: disk.Album, Duration: disk.Duration,
				Source: "local", State: "imported", Message: "已读取本地 STRM，未访问 115"})
		}
		job.Phase = fmt.Sprintf("已扫描 %d 个本地 STRM", job.Processed)
		return nil
	})
}

func cloudSTRMTrack(item CloudItem, disk DiskTrack, path string, unavailable bool) DiskTrack {
	if disk.ID == "" || disk.MetadataSource == "filename" {
		title := trackPrefix.ReplaceAllString(strings.TrimSuffix(item.Name, filepath.Ext(item.Name)), "")
		artist := "Unknown Artist"
		if parts := strings.SplitN(title, " - ", 2); len(parts) == 2 {
			artist, title = strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
		}
		added := disk.AddedAt
		if added.IsZero() {
			added = time.Now().UTC()
		}
		disk.Track = Track{ID: item.TrackID, Title: title, Artist: artist, AlbumArtist: artist, Album: "Unknown Album",
			Format:  strings.TrimPrefix(strings.ToLower(filepath.Ext(item.Name)), "."),
			Library: "cloud", MetadataSource: "filename", AddedAt: added, Favorite: disk.Favorite}
	}
	remote := item.RemoteFile
	disk.File, disk.Remote, disk.Size, disk.Unavailable = path, &remote, item.Size, unavailable
	return disk
}
