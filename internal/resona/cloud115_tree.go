package resona

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const cloudDirectoryUA = "Mozilla/5.0 (compatible; Resona/1.0)"
const cloudMaxDirectories, cloudMaxFiles = 10000, 100000

func (f *cloudFile) UnmarshalJSON(data []byte) error {
	type file cloudFile
	var value struct {
		file
		CID      cloudNumber `json:"cid"`
		Name     string      `json:"n"`
		FileName string      `json:"file_name"`
		SHA1     string      `json:"sha"`
		Size     cloudNumber `json:"s"`
		PickCode string      `json:"pick_code"`
	}
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	*f = cloudFile(value.file)
	if f.Name == "" {
		f.Name = value.Name
	}
	if f.Name == "" {
		f.Name = value.FileName
	}
	if f.SHA1 == "" {
		f.SHA1 = value.SHA1
	}
	if f.Size == "" {
		f.Size = value.Size
	}
	if f.PickCode == "" {
		f.PickCode = value.PickCode
	}
	if f.Category == "" {
		f.Category = "1"
		if f.ID == "" && f.SHA1 == "" {
			f.Category = "0"
		}
	}
	// Web directories use cid/pid, while files use fid/cid.
	if f.Category == "0" {
		if value.CID != "" {
			f.ID = value.CID
		}
	} else if value.CID != "" {
		f.ParentID = value.CID
	}
	return nil
}

func (c *Cloud115) list(ctx context.Context, parent string) ([]cloudFile, error) {
	return c.listFiles(ctx, parent, false)
}

type cloudDirectoryPart struct {
	ID   cloudNumber `json:"cid"`
	Name string      `json:"name"`
}

func (c *Cloud115) listFiles(ctx context.Context, parent string, recursive bool) ([]cloudFile, error) {
	files, _, err := c.listDirectory(ctx, parent, recursive)
	return files, err
}

func (c *Cloud115) listDirectory(ctx context.Context, parent string, recursive bool) ([]cloudFile, []cloudDirectoryPart, error) {
	files := []cloudFile{}
	seen := map[string]bool{}
	total := -1
	for offset := 0; ; {
		var response struct {
			Data   []cloudFile          `json:"data"`
			Count  cloudNumber          `json:"count"`
			CID    cloudNumber          `json:"cid"`
			Offset cloudNumber          `json:"offset"`
			Path   []cloudDirectoryPart `json:"path"`
		}
		form := url.Values{"cid": {parent}, "limit": {"5000"}, "offset": {strconv.Itoa(offset)},
			"show_dir": {"1"}, "cur": {"1"}, "o": {"file_name"}, "asc": {"1"},
			"stdir": {"1"}, "count_folders": {"1"}}
		if recursive {
			form.Set("show_dir", "0")
			form.Set("cur", "0")
			form.Set("count_folders", "0")
			form.Set("stdir", "0")
			form.Set("type", "99")
		}
		if err := c.requestAt(ctx, c.webURL, "GET", "/files", form, cloudDirectoryUA, &response); err != nil {
			return nil, nil, err
		}
		count, err := strconv.Atoi(string(response.Count))
		offsetValue, offsetErr := strconv.Atoi(string(response.Offset))
		if err != nil || count < 0 || count > cloudMaxFiles || (total >= 0 && total != count) ||
			string(response.CID) != parent || (!recursive && len(response.Path) == 0) ||
			(len(response.Path) > 0 && string(response.Path[len(response.Path)-1].ID) != parent) || (recursive && response.Data == nil) ||
			(response.Offset != "" && (offsetErr != nil || offsetValue != offset)) {
			return nil, nil, errors.New("115 目录分页发生变化或返回错误目录，请重新同步；已有索引已保留")
		}
		total = count
		for i := range response.Data {
			f := &response.Data[i]
			if !decimalID(string(f.ID)) || f.ID == "0" || seen[string(f.ID)] || !validCloudTreeName(f.Name) ||
				(f.Category != "0" && f.Category != "1") || (recursive && f.Category != "1") {
				return nil, nil, errors.New("115 目录返回重复或无效条目，请重新同步")
			}
			if !recursive {
				if f.ParentID != "" && string(f.ParentID) != parent {
					return nil, nil, errors.New("115 文件不在请求目录内")
				}
				f.ParentID = cloudNumber(parent)
			}
			seen[string(f.ID)] = true
		}
		files = append(files, response.Data...)
		c.syncProgress(fmt.Sprintf("正在读取文件清单 · 已读取 %d / %d 项", len(files), total))
		offset += len(response.Data)
		if offset > total || (offset < total && len(response.Data) == 0) {
			return nil, nil, errors.New("115 目录未完整返回，请重新同步；已有索引已保留")
		}
		if offset == total {
			return files, response.Path, nil
		}
	}
}

func (c *Cloud115) tree(ctx context.Context, root string) ([]cloudFile, error) {
	if root != "0" {
		files, err := c.bulkTree(ctx, root)
		if err == nil {
			return files, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if errors.Is(err, errCloudAuth) {
			return nil, err
		}
		c.server.logger.Warn("115 批量目录树获取失败，回退逐目录扫描", "error", err)
	}
	type folder struct{ id, path string }
	queue := []folder{{root, ""}}
	files := []cloudFile{}
	seen := map[string]bool{root: true}
	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		c.syncProgress(fmt.Sprintf("正在逐目录扫描 · 剩余 %d 个目录 · 已发现 %d 个文件", len(queue)+1, len(files)))
		children, err := c.list(ctx, current.id)
		if err != nil {
			return nil, err
		}
		for _, f := range children {
			id := string(f.ID)
			if seen[id] {
				return nil, errors.New("115 目录树包含重复条目或循环引用")
			}
			seen[id] = true
			f.Path = filepath.Join(current.path, safeComponent(f.Name))
			if f.Category == "0" {
				if len(seen)-len(files) > cloudMaxDirectories {
					return nil, errors.New("115 目录超过 10000 项，请缩小同步范围")
				}
				queue = append(queue, folder{id, f.Path})
			} else {
				files = append(files, f)
				if len(files) > cloudMaxFiles {
					return nil, errors.New("115 文件超过 100000 项，请缩小同步范围")
				}
			}
		}
	}
	return files, nil
}

// JavStrm supplements get_info with files/file, then reads the proapi folder tree.
func (c *Cloud115) directoryPickCode(ctx context.Context, root string) (string, error) {
	for _, endpoint := range []string{"/files/get_info", "/files/file"} {
		var response struct {
			Data json.RawMessage `json:"data"`
		}
		if err := c.requestAt(ctx, c.webURL, "GET", endpoint, url.Values{"file_id": {root}}, cloudDirectoryUA, &response); err != nil {
			if errors.Is(err, errCloudAuth) || ctx.Err() != nil || endpoint == "/files/file" {
				return "", err
			}
			continue
		}
		data := response.Data
		if len(data) > 0 && data[0] == '[' {
			var entries []json.RawMessage
			if err := json.Unmarshal(data, &entries); err != nil || len(entries) != 1 {
				continue
			}
			data = entries[0]
		}
		var info struct {
			ID       cloudNumber `json:"file_id"`
			CID      cloudNumber `json:"cid"`
			FID      cloudNumber `json:"fid"`
			PickCode string      `json:"pick_code"`
			Pickcode string      `json:"pickcode"`
			PC       string      `json:"pc"`
		}
		if err := json.Unmarshal(data, &info); err != nil {
			continue
		}
		id := string(info.ID)
		if id == "" {
			id = string(info.CID)
		}
		if id != root || info.FID != "" {
			continue
		}
		for _, pc := range []string{info.PickCode, info.Pickcode, info.PC} {
			if pc != "" {
				return pc, nil
			}
		}
	}
	return "", errors.New("115 未返回所选目录的 PickCode")
}

func (c *Cloud115) bulkTree(ctx context.Context, root string) ([]cloudFile, error) {
	c.syncProgress("正在读取所选目录信息")
	pickCode, err := c.directoryPickCode(ctx, root)
	if err != nil {
		return nil, err
	}

	type directory struct {
		ID     cloudNumber `json:"fid"`
		Parent cloudNumber `json:"pid"`
		Name   string      `json:"fn"`
	}
	nodes := map[string]directory{}
	total := -1
	for page := 1; ; page++ {
		var response struct {
			Data struct {
				Count cloudNumber     `json:"count"`
				More  json.RawMessage `json:"has_next_page"`
				List  []directory     `json:"list"`
			} `json:"data"`
		}
		if err := c.requestAt(ctx, c.apiURL, "GET", "/app/2.0/chrome/downfolders", url.Values{
			"pickcode": {pickCode}, "page": {strconv.Itoa(page)}, "per_page": {"5000"},
		}, cloudDirectoryUA, &response); err != nil {
			return nil, err
		}
		data := response.Data
		c.syncProgress(fmt.Sprintf("正在读取目录树 · 第 %d 页 · 已读取 %d 个目录", page, len(nodes)+len(data.List)))
		if data.Count != "" {
			count, err := strconv.Atoi(string(data.Count))
			if err != nil || count < 0 || count > cloudMaxDirectories || total >= 0 && count != total {
				return nil, errors.New("115 目录树数量无效或在扫描期间发生变化")
			}
			total = count
		}
		more := string(data.More)
		if more != "true" && more != "1" && more != `"1"` && more != "false" && more != "0" && more != `"0"` {
			return nil, errors.New("115 目录树缺少有效分页标记")
		}
		for _, node := range data.List {
			id := string(node.ID)
			if !decimalID(id) || id == root || id == "0" || !decimalID(string(node.Parent)) || !validCloudTreeName(node.Name) {
				return nil, errors.New("115 目录树包含无效节点")
			}
			if _, ok := nodes[id]; ok {
				return nil, errors.New("115 目录树包含重复节点")
			}
			nodes[id] = node
		}
		if len(nodes) > cloudMaxDirectories || total >= 0 && len(nodes) > total {
			return nil, errors.New("115 目录树数量超出限制或与分页不符")
		}
		if more == "false" || more == "0" || more == `"0"` {
			if total >= 0 && len(nodes) != total {
				return nil, errors.New("115 目录树分页不完整")
			}
			break
		}
		if len(data.List) == 0 || len(nodes) == cloudMaxDirectories {
			return nil, errors.New("115 目录树分页不完整")
		}
	}
	paths := map[string]string{root: ""}
	visiting := map[string]bool{}
	var resolve func(string) (string, error)
	resolve = func(id string) (string, error) {
		if value, ok := paths[id]; ok {
			return value, nil
		}
		node, ok := nodes[id]
		if !ok || visiting[id] {
			return "", errors.New("115 目录树包含缺失父目录或循环引用")
		}
		visiting[id] = true
		parent, err := resolve(string(node.Parent))
		if err != nil {
			return "", err
		}
		delete(visiting, id)
		paths[id] = filepath.Join(parent, safeComponent(node.Name))
		return paths[id], nil
	}
	for id := range nodes {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if _, err := resolve(id); err != nil {
			return nil, err
		}
	}
	files, err := c.listFiles(ctx, root, true)
	if err != nil {
		return nil, err
	}
	for i := range files {
		f := &files[i]
		path, ok := paths[string(f.ParentID)]
		if !ok {
			return nil, errors.New("115 文件父目录不在所选目录树内")
		}
		f.Path = filepath.Join(path, safeComponent(f.Name))
	}
	return files, nil
}

func validCloudTreeName(name string) bool {
	return name != "" && name != "." && name != ".." && !strings.ContainsAny(name, "/\\\r\n\x00")
}

// Commit only a complete directory tree; probing never delays bulk STRM generation.
func (c *Cloud115) syncTree(ctx context.Context) error {
	settings := c.snapshot()
	files, err := c.tree(ctx, settings.Settings.RootID)
	if err != nil {
		return err
	}
	siblings := make(map[string]map[string]RemoteFile)
	for _, f := range files {
		parent := string(f.ParentID)
		if siblings[parent] == nil {
			siblings[parent] = make(map[string]RemoteFile)
		}
		size, _ := strconv.ParseInt(string(f.Size), 10, 64)
		if f.PickCode != "" && validHex(f.SHA1, 40) {
			siblings[parent][strings.ToLower(f.Name)] = RemoteFile{Account: settings.Account, FileID: string(f.ID), PickCode: f.PickCode, SHA1: strings.ToLower(f.SHA1), Size: size}
		}
	}
	seen := map[string]bool{}
	c.syncProgress("正在更新远端文件索引")
	c.dataMu.Lock()
	defer c.dataMu.Unlock()
	return c.server.store.updateCloud(func(st *libraryState) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		for _, f := range files {
			if err := ctx.Err(); err != nil {
				return err
			}
			if !supported(f.Name) {
				continue
			}
			size, err := strconv.ParseInt(string(f.Size), 10, 64)
			if err != nil || size <= 0 || !validHex(f.SHA1, 40) || f.PickCode == "" {
				return errors.New("115 音乐文件信息不完整，请重新同步")
			}
			id := cloudTrackID(settings.Account, string(f.ID))
			seen[id] = true
			fingerprint := strings.ToLower(f.SHA1) + ":" + string(f.Size)
			item, exists := st.Cloud.Items[id]
			item.RemoteFile = RemoteFile{Account: settings.Account, FileID: string(f.ID), PickCode: f.PickCode, SHA1: strings.ToLower(f.SHA1), Size: size}
			item.TrackID, item.Name, item.Path, item.UpdatedAt = id, f.Name, f.Path, time.Now().UTC()
			item.Cover, item.LRC = nil, nil
			for _, name := range []string{"cover.jpg", "folder.jpg", "cover.png", "folder.png"} {
				if cover, ok := siblings[string(f.ParentID)][name]; ok && cover.Size > 0 && cover.Size <= 5<<20 {
					copy := cover
					item.Cover = &copy
					break
				}
			}
			if lrc, ok := siblings[string(f.ParentID)][strings.ToLower(strings.TrimSuffix(f.Name, filepath.Ext(f.Name))+".lrc")]; ok && lrc.Size > 0 && lrc.Size <= maxLyricsSize {
				copy := lrc
				item.LRC = &copy
			}
			for _, sidecar := range []*RemoteFile{item.Cover, item.LRC} {
				if sidecar != nil {
					fingerprint += ":" + sidecar.SHA1 + ":" + strconv.FormatInt(sidecar.Size, 10)
				}
			}
			if !exists || item.Fingerprint != fingerprint || item.State == "missing" {
				item.State, item.Error = "pending", ""
				if old, ok := st.Tracks[id]; ok {
					old.Unavailable = true
					st.Tracks[id] = old
				}
			}
			item.Fingerprint = fingerprint
			st.Cloud.Items[id] = item
			if old, ok := st.Tracks[id]; ok {
				remote := item.RemoteFile
				old.Remote = &remote
				st.Tracks[id] = old
			}
		}
		for id, item := range st.Cloud.Items {
			if !seen[id] && item.Account == settings.Account {
				item.State, item.Error = "missing", "远端文件已不在同步目录中"
				st.Cloud.Items[id] = item
				if old, ok := st.Tracks[id]; ok {
					old.Unavailable = true
					st.Tracks[id] = old
				}
			}
		}
		st.Cloud.LastSync = time.Now().UTC()
		return nil
	})
}
