package resona

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestCloudAccountProfileAndFallback(t *testing.T) {
	for _, fallback := range []bool{false, true} {
		t.Run(map[bool]string{false: "primary", true: "fallback"}[fallback], func(t *testing.T) {
			s := testServer(t)
			seedCloud(t, s)
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Cookie") != s.cloud.summary().Cookie {
					t.Error("profile is missing its Cookie")
				}
				if fallback && r.URL.Path == "/user/info" {
					w.WriteHeader(405)
					return
				}
				if r.URL.Path == "/files/index_info" {
					cloudResponse(w, map[string]any{"space_info": map[string]any{
						"all_total": map[string]any{"size": "1000"}, "all_use": map[string]any{"size": 250},
					}})
					return
				}
				cloudResponse(w, map[string]any{"user_id": "42", "user_name": "Profile Account",
					"user_face_m": "//face.115.com/avatar.png", "mark3": 1023})
			}))
			defer upstream.Close()
			s.cloud.webURL, s.cloud.userURL = upstream.URL, upstream.URL
			token := loginToken(t, s)
			if w := request(s.Handler(), "GET", "/api/v1/cloud115/account", "", ""); w.Code != 401 {
				t.Fatal("public account endpoint", w.Code)
			}
			w := request(s.Handler(), "GET", "/api/v1/cloud115/account", "", token)
			var profile cloudAccount
			if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &profile) != nil {
				t.Fatal(w.Code, w.Body.String())
			}
			if profile.ID != "42" || profile.Name != "Profile Account" || profile.Avatar != "https://face.115.com/avatar.png" ||
				profile.Membership != "年费 VIP" || profile.Space == nil || profile.Space.Remaining != 750 {
				t.Fatalf("profile: %+v", profile)
			}
			if strings.Contains(strings.ToLower(w.Body.String()), "cookie") || strings.Contains(w.Body.String(), "private") {
				t.Fatal("profile exposes credentials")
			}
		})
	}
}

func TestCloudProfileFailureKeepsLogin(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
	}))
	defer upstream.Close()
	s.cloud.webURL, s.cloud.userURL = upstream.URL, upstream.URL
	before := s.cloud.summary().Cookie
	w := request(s.Handler(), "GET", "/api/v1/cloud115/account", "", loginToken(t, s))
	if w.Code != 502 || s.cloud.summary().Cookie != before {
		t.Fatal("optional profile failure invalidated the login", w.Code)
	}
}

func TestCloudAccountRejectsUnsafeAndInactiveData(t *testing.T) {
	for _, avatar := range []string{"http://face.115.com/a", "https://115.com.evil.test/a", "javascript:alert(1)"} {
		var data cloudObject
		encoded, _ := json.Marshal(map[string]any{"user_id": "42", "user_face_m": avatar,
			"vip_info":   map[string]any{"is_vip": 0, "level_name": "VIP"},
			"space_info": map[string]any{"all_total": map[string]any{"size": "10"}, "all_use": map[string]any{"size": "11"}}})
		_ = json.Unmarshal(encoded, &data)
		profile := cloudAccount{ID: "42"}
		if !profile.merge(data) || profile.Avatar != "" || profile.Membership != "普通账号" || profile.Space != nil {
			t.Fatalf("untrusted profile accepted: %+v", profile)
		}
	}
	var wrong cloudObject
	_ = json.Unmarshal([]byte(`{"user_id":"43","user_name":"Another Account"}`), &wrong)
	profile := cloudAccount{ID: "42"}
	if profile.merge(wrong) {
		t.Fatal("another account accepted")
	}
}

func TestCloudDailySchedulePersistsAndMigrates(t *testing.T) {
	s := testServer(t)
	seedCloud(t, s)
	token := loginToken(t, s)
	for _, body := range []string{
		`{"root_id":"0","sync_schedule":{"mode":"daily","time":"24:00"}}`,
		`{"root_id":"0","sync_schedule":{"mode":"daily","time":"3:00"}}`,
		`{"root_id":"0","sync_schedule":{"mode":"invalid"}}`,
	} {
		if w := request(s.Handler(), "PUT", "/api/v1/cloud115", body, token); w.Code != 400 {
			t.Fatal("invalid daily schedule accepted", w.Code, w.Body.String())
		}
	}
	for _, tc := range []struct {
		body string
		want ScanSchedule
	}{
		{`{"root_id":"0","enabled":true,"sync_schedule":{"mode":"daily","time":"21:45"}}`, ScanSchedule{Mode: "daily", Time: "21:45"}},
		{`{"root_id":"0","enabled":true,"sync_schedule":{"mode":"manual","time":"21:45"}}`, ScanSchedule{Mode: "manual", Time: "21:45"}},
		{`{"root_id":"0","enabled":true,"interval_minutes":60}`, ScanSchedule{Mode: "daily", Time: "03:00"}},
		{`{"root_id":"0","enabled":true,"interval_minutes":0}`, ScanSchedule{Mode: "manual", Time: "03:00"}},
	} {
		if w := request(s.Handler(), "PUT", "/api/v1/cloud115", tc.body, token); w.Code != 200 {
			t.Fatal(w.Code, w.Body.String())
		}
		restarted, err := NewServer(context.Background(), s.config)
		if err != nil {
			t.Fatal(err)
		}
		if got := restarted.cloud.summary().Settings.syncSchedule(); got != tc.want {
			t.Fatal("schedule lost after restart", got, tc.want)
		}
		select {
		case <-s.cloud.scheduleChanged:
		default:
			t.Fatal("saving did not notify scheduler")
		}
	}
	legacy := CloudSettings{IntervalMinutes: 60}
	now := time.Date(2026, 10, 26, 2, 59, 0, 0, time.FixedZone("CST", 8*3600))
	if got := legacy.syncSchedule().next(now); !got.Equal(now.Add(time.Minute)) {
		t.Fatal("legacy plan did not migrate to daily 03:00", got)
	}
}
