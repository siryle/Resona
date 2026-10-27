package resona

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestScanSchedulePersistsAndOverridesEnvironment(t *testing.T) {
	s := testServer(t)
	token := loginToken(t, s)
	for _, body := range []string{
		`{"mode":"daily","time":"24:00"}`, `{"mode":"daily","time":"3:00"}`,
		`{"mode":"interval","interval":"30s"}`, `{"mode":"interval","interval":"169h"}`,
		`{"mode":"other"}`,
	} {
		if w := request(s.Handler(), "PUT", "/api/v1/settings/scan", body, token); w.Code != 400 {
			t.Fatal("invalid schedule accepted", body, w.Code)
		}
	}
	for _, schedule := range []ScanSchedule{
		{Mode: "interval", Interval: "45m", Time: "03:00"},
		{Mode: "daily", Time: "04:30", Interval: "45m"},
		{Mode: "manual", Interval: "45m", Time: "04:30"},
	} {
		data, _ := json.Marshal(schedule)
		if w := request(s.Handler(), "PUT", "/api/v1/settings/scan", string(data), token); w.Code != 200 {
			t.Fatal("schedule save failed", w.Code, w.Body.String())
		}
		c := s.config
		c.ScanInterval = 15 * time.Minute
		restarted, err := NewServer(context.Background(), c)
		if err != nil || restarted.scanSchedule() != schedule.daily() {
			t.Fatal("saved schedule lost after restart", err)
		}
	}
	if w := request(s.Handler(), "PUT", "/api/v1/settings/scan", `{"mode":"manual"}`, ""); w.Code != 401 {
		t.Fatal("unauthenticated schedule update")
	}
	w := request(s.Handler(), "GET", "/api/v1/system", "", token)
	if !strings.Contains(w.Body.String(), `"scan_interval":"0s"`) {
		t.Fatal("system still reports fixed interval", w.Body.String())
	}
}

func TestScanScheduleNextRun(t *testing.T) {
	zone := time.FixedZone("CST", 8*3600)
	now := time.Date(2026, 10, 26, 4, 0, 0, 0, zone)
	for _, tc := range []struct {
		schedule ScanSchedule
		want     time.Time
	}{
		{ScanSchedule{Mode: "manual"}, time.Time{}},
		{ScanSchedule{Mode: "interval", Interval: "90m"}, now.Add(90 * time.Minute)},
		{ScanSchedule{Mode: "daily", Time: "04:30"}, now.Add(30 * time.Minute)},
		{ScanSchedule{Mode: "daily", Time: "04:00"}, now.AddDate(0, 0, 1)},
		{ScanSchedule{Mode: "daily", Time: "03:00"}, now.AddDate(0, 0, 1).Add(-time.Hour)},
	} {
		if got := tc.schedule.next(now); !got.Equal(tc.want) {
			t.Fatalf("%+v: next=%v want=%v", tc.schedule, got, tc.want)
		}
	}
}
