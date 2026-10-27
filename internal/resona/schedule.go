package resona

import (
	"errors"
	"net/http"
	"time"
)

type ScanSchedule struct {
	Mode     string `json:"mode"`
	Interval string `json:"interval"`
	Time     string `json:"time"`
}

// Older interval plans become daily plans without re-enabling manual schedules.
func (s ScanSchedule) daily() ScanSchedule {
	if s.Mode == "interval" {
		s.Mode = "daily"
		if t, err := time.Parse("15:04", s.Time); err != nil {
			s.Time = "03:00"
		} else {
			s.Time = t.Format("15:04")
		}
	}
	if s.Time == "" {
		s.Time = "03:00"
	}
	s.Interval = ""
	return s
}

func (s *Server) scanSchedule() ScanSchedule {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	if saved := s.store.state.ScanSchedule; saved != nil {
		return saved.daily()
	}
	if s.config.ScanInterval == 0 {
		return ScanSchedule{Mode: "manual", Time: "03:00"}
	}
	return ScanSchedule{Mode: "daily", Time: "03:00"}
}

func (s ScanSchedule) validate() error {
	switch s.Mode {
	case "manual":
		return nil
	case "interval":
		d, err := time.ParseDuration(s.Interval)
		if err == nil && d >= time.Minute && d <= 7*24*time.Hour {
			return nil
		}
	case "daily":
		t, err := time.Parse("15:04", s.Time)
		if err == nil && t.Format("15:04") == s.Time {
			return nil
		}
	}
	return errors.New("请选择手动执行、1 分钟至 7 天的间隔，或有效的每日时间（HH:mm）")
}

func (s ScanSchedule) next(now time.Time) time.Time {
	switch s.Mode {
	case "interval":
		d, err := time.ParseDuration(s.Interval)
		if err == nil && d >= time.Minute {
			return now.Add(d)
		}
	case "daily":
		t, err := time.Parse("15:04", s.Time)
		if err == nil {
			next := time.Date(now.Year(), now.Month(), now.Day(), t.Hour(), t.Minute(), 0, 0, now.Location())
			if !next.After(now) {
				next = next.AddDate(0, 0, 1)
			}
			return next
		}
	}
	return time.Time{}
}

func (s ScanSchedule) description() string {
	switch s.Mode {
	case "interval":
		return s.Interval
	case "daily":
		return "每日 " + s.Time
	default:
		return "0s"
	}
}

func (s *Server) getScanSchedule(w http.ResponseWriter, r *http.Request) {
	jsonResponse(w, 200, map[string]any{"settings": s.scanSchedule(), "timezone": time.Now().Format("MST -07:00")})
}

func (s *Server) setScanSchedule(w http.ResponseWriter, r *http.Request) {
	var schedule ScanSchedule
	if !decodeBody(w, r, &schedule) {
		return
	}
	if err := schedule.validate(); err != nil {
		apiError(w, 400, err.Error())
		return
	}
	schedule = schedule.daily()
	if err := s.store.update(func(st *libraryState) error { st.ScanSchedule = &schedule; return nil }); err != nil {
		apiError(w, 500, "无法保存执行计划，请检查数据目录权限")
		return
	}
	select {
	case s.scanScheduleChanged <- struct{}{}:
	default:
	}
	s.logger.With("category", "settings").Info("整理与刮削执行计划已更新", "mode", schedule.Mode, "schedule", schedule.description())
	s.getScanSchedule(w, r)
}

func (s *Server) scheduleScans() {
	for {
		schedule := s.scanSchedule()
		next := schedule.next(time.Now())
		var timer *time.Timer
		var tick <-chan time.Time
		if !next.IsZero() {
			timer = time.NewTimer(time.Until(next))
			tick = timer.C
		}
		select {
		case <-s.ctx.Done():
			if timer != nil {
				timer.Stop()
			}
			return
		case <-s.scanScheduleChanged:
			if timer != nil {
				timer.Stop()
			}
		case <-tick:
			// A saved change takes priority even if its wake-up races the timer.
			if schedule != s.scanSchedule() {
				continue
			}
			if _, err := s.scanner.Start(s.ctx, false); err != nil {
				s.logger.With("category", "scan").Info("定时整理与刮削已跳过", "reason", err)
			} else {
				s.logger.With("category", "scan").Info("定时整理与刮削已启动", "schedule", schedule.description())
			}
		}
	}
}
