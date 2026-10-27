package resona

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type cloudAccountSpace struct {
	Total     int64 `json:"total"`
	Used      int64 `json:"used"`
	Remaining int64 `json:"remaining"`
}

type cloudAccount struct {
	ID         string             `json:"id"`
	Name       string             `json:"name"`
	Avatar     string             `json:"avatar"`
	Membership string             `json:"membership"`
	Space      *cloudAccountSpace `json:"space"`
}

type cloudObject map[string]json.RawMessage

func (o cloudObject) object(key string) cloudObject {
	var value cloudObject
	_ = json.Unmarshal(o[key], &value)
	return value
}

func (o cloudObject) text(keys ...string) string {
	for _, key := range keys {
		var value cloudNumber
		if json.Unmarshal(o[key], &value) == nil && value != "" {
			return string(value)
		}
	}
	return ""
}

func (a *cloudAccount) merge(data cloudObject) bool {
	for _, key := range []string{"user_info", "user"} {
		if nested := data.object(key); nested != nil {
			if !a.merge(nested) {
				return false
			}
		}
	}
	if id := data.text("user_id", "uid", "id"); id != "" && strings.SplitN(id, "_", 2)[0] != a.ID {
		return false
	}
	if name := data.text("user_name", "uname", "name"); name != "" {
		a.Name = name
	}
	avatar := data.text("user_face_m", "user_face", "face_s")
	if avatar == "" {
		avatar = data.object("face").text("face_m", "face_s", "face")
	}
	if strings.HasPrefix(avatar, "//") {
		avatar = "https:" + avatar
	}
	if strings.HasPrefix(avatar, "https://") && validCloudURL(avatar) {
		a.Avatar = avatar
	}
	vip := data.object("vip_info")
	if vip == nil {
		vip = data.object("vip")
	}
	label := vip.text("level_name", "vip_name", "name")
	if label == "" {
		label = data.text("level_name")
	}
	mark := data.text("mark3")
	if mark == "" {
		mark = vip.text("mark3")
	}
	switch mark {
	case "0":
		a.Membership = "普通账号"
	case "1":
		a.Membership = "月费 VIP"
	case "11":
		a.Membership = "体验 VIP"
	case "12":
		a.Membership = "尝鲜 VIP"
	case "127":
		a.Membership = "黄金 VIP"
	case "255":
		a.Membership = "铂金 VIP"
	case "1023":
		a.Membership = "年费 VIP"
	case "10231":
		a.Membership = "高级 VIP"
	case "10235":
		a.Membership = "特级 VIP"
	case "10239":
		a.Membership = "超级 VIP"
	case "1048575":
		a.Membership = "长期 VIP"
	default:
		flag := vip["is_vip"]
		if flag == nil {
			flag = data["is_vip"]
		}
		switch strings.Trim(string(flag), `"`) {
		case "0", "false":
			a.Membership = "普通账号"
		default:
			if label != "" {
				a.Membership = label
			} else if string(flag) == "true" || vip.text("is_vip", "vip_level") != "" && vip.text("is_vip", "vip_level") != "0" {
				a.Membership = "VIP"
			}
		}
	}
	space := data.object("rt_space_info")
	if space == nil {
		space = data.object("space_info")
	}
	if space == nil {
		space = data
	}
	total, totalErr := strconv.ParseInt(space.object("all_total").text("size"), 10, 64)
	used, usedErr := strconv.ParseInt(space.object("all_use").text("size"), 10, 64)
	if totalErr == nil && usedErr == nil && total > 0 && used >= 0 && used <= total {
		a.Space = &cloudAccountSpace{Total: total, Used: used, Remaining: total - used}
	}
	return true
}

// Optional profile reads never invalidate a working playback Cookie.
func (c *Cloud115) account(w http.ResponseWriter, r *http.Request) {
	state := c.summary()
	if state.Cookie == "" {
		apiError(w, 409, "请先扫码登录 115")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	profile := cloudAccount{ID: state.Account, Name: state.AccountName}
	read := func(base, path string, query url.Values) bool {
		var response struct {
			Data json.RawMessage `json:"data"`
		}
		if err := c.raw(ctx, "GET", base+path, query, state.Cookie, "", &response); err != nil {
			return false
		}
		var data cloudObject
		// Some account endpoints wrap their object in a JSON string.
		var text string
		if json.Unmarshal(response.Data, &text) == nil {
			response.Data = json.RawMessage(text)
		}
		next := profile
		if json.Unmarshal(response.Data, &data) != nil || !next.merge(data) {
			return false
		}
		if path == "/user/info" || query.Get("ac") == "get_user_aq" {
			if data.text("user_id", "uid", "id") == "" && data.object("user_info").text("user_id", "uid", "id") == "" &&
				data.object("user").text("user_id", "uid", "id") == "" {
				return false
			}
		}
		profile = next
		return true
	}
	if !read(c.webURL, "/user/info", nil) {
		if !read(c.userURL, "/", url.Values{"ct": {"ajax"}, "ac": {"get_user_aq"}}) {
			apiError(w, 502, "账号资料暂时无法读取，已有设置与任务仍可使用")
			return
		}
	}
	if profile.Membership == "" {
		read(c.userURL, "/", url.Values{"ct": {"ajax"}, "ac": {"nav"}})
	}
	if profile.Space == nil {
		read(c.webURL, "/files/index_info", url.Values{"count_space_nums": {"0"}})
	}
	if current := c.summary(); current.Cookie != state.Cookie || current.Account != state.Account {
		apiError(w, 409, "115 账号已更换，请刷新资料")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	jsonResponse(w, 200, profile)
}
