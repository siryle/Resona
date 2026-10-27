package resona

import (
	"context"
	"crypto/rand"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

func matchesCloudLyrics(data []byte, file RemoteFile) bool {
	digest := sha1.Sum(data)
	return int64(len(data)) == file.Size && strings.EqualFold(hex.EncodeToString(digest[:]), file.SHA1)
}

func (c *Cloud115) syncLyrics(ctx context.Context) error {
	state := c.snapshot()
	var ids []string
	for id, item := range state.Items {
		if item.Account == state.Account && item.State != "missing" && item.State != "skipped" && item.LRC != nil {
			ids = append(ids, id)
		}
	}
	slices.Sort(ids)
	logger := c.server.logger.With("category", "strm")
	logger.Info("115 开始同步同目录歌词", "total", len(ids))
	synced, unchanged, failed := 0, 0, 0
	for index, id := range ids {
		if err := ctx.Err(); err != nil {
			return err
		}
		item := state.Items[id]
		c.syncProgress(fmt.Sprintf("STRM 已生成，正在同步歌词 · %d / %d", index+1, len(ids)))
		same, err := c.syncLyric(ctx, item)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			failed++
			logger.Warn("115 同目录歌词同步失败", "file", item.Path, "reason", err)
			if cloudRestricted(err) || errors.Is(err, errCloudCookieLink) {
				message := fmt.Sprintf("STRM 已生成，网盘音乐库已刷新；歌词同步已暂停：%s；已同步 %d，未变化 %d，剩余 %d。稍后重新生成可补齐歌词",
					err, synced, unchanged, len(ids)-index)
				c.syncProgress(message)
				logger.Warn("115 歌词同步已暂停，保留已生成 STRM 和已有歌词", "reason", err, "remaining", len(ids)-index)
				return nil
			}
			if errors.Is(err, errCloudAuth) {
				return err
			}
		} else if same {
			unchanged++
		} else {
			synced++
			logger.Info("115 同目录歌词已同步", "file", item.Path)
		}
	}
	message := fmt.Sprintf("STRM 已生成，网盘音乐库已刷新；歌词已同步 %d，未变化 %d，失败 %d", synced, unchanged, failed)
	c.syncProgress(message)
	logger.Info("115 同目录歌词同步完成", "synced", synced, "unchanged", unchanged, "failed", failed)
	return nil
}

func (c *Cloud115) syncLyric(ctx context.Context, item CloudItem) (bool, error) {
	rootPath := filepath.Join(c.server.config.DataDir, "cloud115", "strm")
	readExisting := func() bool {
		c.dataMu.Lock()
		defer c.dataMu.Unlock()
		path := c.strmPath(item)
		if !within(rootPath, path) {
			return false
		}
		root, err := os.OpenRoot(rootPath)
		if err != nil {
			return false
		}
		defer root.Close()
		name, _ := filepath.Rel(rootPath, strings.TrimSuffix(path, ".strm")+".lrc")
		info, err := root.Lstat(name)
		if err != nil || !info.Mode().IsRegular() || info.Size() > maxLyricsSize {
			return false
		}
		file, err := root.Open(name)
		if err != nil {
			return false
		}
		defer file.Close()
		data, err := io.ReadAll(io.LimitReader(file, maxLyricsSize+1))
		return err == nil && matchesCloudLyrics(data, *item.LRC)
	}
	if readExisting() {
		return true, nil
	}
	downloadCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	data, err := c.readSidecar(downloadCtx, *item.LRC)
	if err != nil {
		return false, err
	}
	if !matchesCloudLyrics(data, *item.LRC) {
		return false, errors.New("网盘歌词文件校验失败")
	}
	if _, err := makeLyrics(string(data), "cloud"); err != nil {
		return false, err
	}
	c.dataMu.Lock()
	defer c.dataMu.Unlock()
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if !c.sameItem(item) {
		return false, errors.New("歌词对应的歌曲索引已变化，请重新同步")
	}
	// Resolve again after downloading: a concurrent probe may have moved the STRM.
	path := c.strmPath(item)
	if !within(rootPath, path) {
		return false, errors.New("歌词路径超出 STRM 目录")
	}
	root, err := os.OpenRoot(rootPath)
	if err != nil {
		return false, err
	}
	defer root.Close()
	name, _ := filepath.Rel(rootPath, path)
	info, err := root.Lstat(name)
	if err != nil || !info.Mode().IsRegular() {
		return false, errors.New("STRM 已删除或不是常规文件，跳过歌词同步")
	}
	name = strings.TrimSuffix(name, ".strm") + ".lrc"
	temporary := filepath.Join(filepath.Dir(name), ".lyrics-"+rand.Text())
	file, err := root.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0777)
	if err != nil {
		return false, err
	}
	defer root.Remove(temporary)
	_, err = file.Write(data)
	if err == nil {
		err = file.Chmod(0777)
	}
	if err = errors.Join(err, file.Close(), ctx.Err()); err != nil {
		return false, err
	}
	return false, root.Rename(temporary, name)
}
