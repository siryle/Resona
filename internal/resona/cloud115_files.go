package resona

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"
)

func cloudManagedPath(value string) (string, error) {
	if value == "" {
		value = "/"
	}
	if !strings.HasPrefix(value, "/") || path.Clean(value) != value ||
		strings.ContainsAny(value, "\\\x00") || len(value) > 4096 {
		return "", errors.New("115 路径须为规范绝对路径，例如 /音乐")
	}
	return value, nil
}

type cloudBrowser struct {
	cloud *Cloud115
	ctx   context.Context
	dirs  map[string][]cloudFile
}

func (b *cloudBrowser) list(id string) ([]cloudFile, error) {
	if items, ok := b.dirs[id]; ok {
		return items, nil
	}
	items, err := b.cloud.list(b.ctx, id)
	if err == nil {
		b.dirs[id] = items
	}
	return items, err
}

func (b *cloudBrowser) lookup(location string) (cloudFile, error) {
	current := cloudFile{ID: "0", Category: "0", Name: "/"}
	if location == "/" {
		return current, nil
	}
	for _, part := range strings.Split(strings.TrimPrefix(location, "/"), "/") {
		if current.Category != "0" {
			return cloudFile{}, errors.New("115 路径包含非目录项")
		}
		items, err := b.list(string(current.ID))
		if err != nil {
			return cloudFile{}, err
		}
		var found *cloudFile
		for _, item := range items {
			if item.Name == part {
				if found != nil {
					return cloudFile{}, errors.New("115 目录包含重名项，无法安全操作")
				}
				copy := item
				found = &copy
			}
		}
		if found == nil {
			return cloudFile{}, errors.New("115 文件或目录不存在")
		}
		current = *found
	}
	return current, nil
}

func (c *Cloud115) files(w http.ResponseWriter, r *http.Request) {
	if c.summary().Cookie == "" {
		apiError(w, 409, "请先扫码登录 115")
		return
	}
	location, err := cloudManagedPath(r.URL.Query().Get("path"))
	if err != nil {
		apiError(w, 400, err.Error())
		return
	}
	browser := cloudBrowser{c, r.Context(), map[string][]cloudFile{}}
	folder, err := browser.lookup(location)
	if err != nil || folder.Category != "0" {
		apiError(w, 502, "无法访问 115 目录，请检查路径或登录状态")
		return
	}
	files, err := browser.list(string(folder.ID))
	if err != nil {
		apiError(w, 502, err.Error())
		return
	}
	items := []fileEntry{}
	for _, file := range files {
		kind := strings.ToUpper(strings.TrimPrefix(path.Ext(file.Name), "."))
		if file.Category == "0" {
			kind = "文件夹"
		} else if kind == "" {
			kind = "文件"
		}
		size, _ := strconv.ParseInt(string(file.Size), 10, 64)
		modified := time.Time{}
		if stamp, err := strconv.ParseInt(string(file.Modified), 10, 64); err == nil && stamp > 0 {
			modified = time.Unix(stamp, 0).UTC()
		}
		items = append(items, fileEntry{file.Name, path.Join(location, file.Name), kind, size, modified, false})
	}
	jsonResponse(w, 200, map[string]any{"items": items, "path": location})
}

func (c *Cloud115) operateFiles(w http.ResponseWriter, r *http.Request) {
	var body fileOperation
	if !decodeBody(w, r, &body) {
		return
	}
	if (body.Action != "copy" && body.Action != "move" && body.Action != "rename" && body.Action != "delete") ||
		len(body.Paths) == 0 || len(body.Paths) > 100 || (body.Action == "rename" && len(body.Paths) != 1) {
		apiError(w, 400, "请选择 1 到 100 项及有效的操作")
		return
	}
	for i, value := range body.Paths {
		clean, err := cloudManagedPath(value)
		if err != nil || clean == "/" || value == "" {
			apiError(w, 400, "115 来源路径无效或为根目录")
			return
		}
		for _, other := range body.Paths[:i] {
			if clean == other || strings.HasPrefix(clean, other+"/") || strings.HasPrefix(other, clean+"/") {
				apiError(w, 400, "请选择互不包含且不重复的条目")
				return
			}
		}
	}
	if body.Action != "delete" {
		if _, err := cloudManagedPath(body.Target); err != nil || body.Target == "" {
			apiError(w, 400, "115 目标路径无效")
			return
		}
	}
	c.mu.Lock()
	if c.busyLocked() || c.summary().Cookie == "" {
		c.mu.Unlock()
		apiError(w, 409, "请登录 115，并等待生成、预探测及其他文件操作完成")
		return
	}
	c.fileBusy = true
	c.mu.Unlock()
	defer func() { c.mu.Lock(); c.fileBusy = false; c.mu.Unlock() }()
	browser := cloudBrowser{c, r.Context(), map[string][]cloudFile{}}
	completed := 0
	for _, source := range body.Paths {
		if err := c.operateCloudFile(&browser, body, source); err != nil {
			c.server.logger.Warn("115 文件操作未完成", "action", body.Action, "file", source, "reason", err)
			jsonResponse(w, 409, map[string]any{"error": fmt.Sprintf("已完成 %d 项；%s：%s", completed, path.Base(source), err), "completed": completed})
			return
		}
		completed++
		c.server.logger.Info("115 文件操作已完成", "action", body.Action, "file", source)
	}
	jsonResponse(w, 200, map[string]int{"completed": completed})
}

func (c *Cloud115) operateCloudFile(browser *cloudBrowser, body fileOperation, source string) error {
	item, err := browser.lookup(source)
	if err != nil {
		return err
	}
	endpoint, form := "/rb/delete", url.Values{"fid": {string(item.ID)}}
	if body.Action != "delete" {
		destination, name := body.Target, item.Name
		if body.Action == "rename" {
			destination, name = path.Dir(body.Target), path.Base(body.Target)
			if destination != path.Dir(source) || !validCloudTreeName(name) {
				return errors.New("重命名只能修改当前目录中的文件名")
			}
		}
		target := path.Join(destination, name)
		if target == source || strings.HasPrefix(target, source+"/") {
			return errors.New("不能复制或移动到自身及子目录")
		}
		folder, err := browser.lookup(destination)
		if err != nil {
			return err
		}
		if folder.Category != "0" {
			return errors.New("目标必须是目录")
		}
		items, err := browser.list(string(folder.ID))
		if err != nil {
			return err
		}
		for _, existing := range items {
			if existing.Name == name {
				return errors.New("目标名称已存在，已保留原文件")
			}
		}
		switch body.Action {
		case "rename":
			endpoint, form = "/files/batch_rename", url.Values{"files_new_name[" + string(item.ID) + "]": {name}}
		case "move":
			endpoint, form = "/files/move", url.Values{"fid": {string(item.ID)}, "pid": {string(folder.ID)}}
		case "copy":
			endpoint, form = "/files/copy", url.Values{"fid[0]": {string(item.ID)}, "pid": {string(folder.ID)}}
		}
	}
	if err := c.requestAt(browser.ctx, c.webURL, "POST", endpoint, form, cloudDirectoryUA, nil); err != nil {
		return err
	}
	// Invalidate lookup results after every mutation, including partial batches.
	clear(browser.dirs)
	return nil
}
