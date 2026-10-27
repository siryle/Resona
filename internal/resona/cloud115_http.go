package resona

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type cloudHTTPError struct {
	Status           int
	Path, RetryAfter string
}

type cloudDownloadError struct {
	cause error
	http  bool
}

func (e *cloudDownloadError) Unwrap() error { return e.cause }

func (e *cloudDownloadError) Error() string {
	var rejection *cloudHTTPError
	errors.As(e.cause, &rejection)
	hint := "请稍后重试或重新扫码登录，已有索引和探测队列已保留"
	if !e.http && rejection.Status == http.StatusMethodNotAllowed {
		hint = "可在设置 → 115 网盘手动选择 HTTP 兼容模式（Cookie 明文），或稍后重试"
	}
	return fmt.Sprintf("115 下载接口受限（HTTP %d）；%s", rejection.Status, hint)
}

func (e *cloudHTTPError) Error() string {
	return fmt.Sprintf("115 返回 HTTP %d（接口 %s），请稍后重试；已有索引已保留", e.Status, e.Path)
}

func cloudRestricted(err error) bool {
	var rejection *cloudHTTPError
	return errors.As(err, &rejection) && (rejection.Status == http.StatusMethodNotAllowed || rejection.Status == http.StatusTooManyRequests)
}

// Follow MetaCine's bounded rejection cooldown without replaying ambiguous failures.
func cloudRetryDelay(header string, attempt int) time.Duration {
	header = strings.TrimSpace(header)
	if seconds, err := strconv.ParseInt(header, 10, 64); err == nil && seconds > 0 {
		return time.Duration(min(seconds, 120)) * time.Second
	}
	if until, err := http.ParseTime(header); err == nil && time.Until(until) > 0 {
		return min(time.Until(until), 120*time.Second)
	}
	return time.Second << min(attempt, 3)
}

func cloudWait(ctx context.Context, delay time.Duration) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if delay <= 0 {
		return nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
