package resona

import (
	"net/http"
	"strings"
)

// Task control reads only small fields, never copies or sorts the song index.
func (c *Cloud115) summary() CloudState {
	c.server.store.mu.RLock()
	defer c.server.store.mu.RUnlock()
	st := c.server.store.state.Cloud
	st.Items, st.ProbeQueue = nil, nil
	return st
}

func (c *Cloud115) syncProgress(message string) {
	c.mu.Lock()
	if c.busy && !c.syncStopping {
		c.message = message
	}
	c.mu.Unlock()
}

func (c *Cloud115) progressData() map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.server.store.mu.RLock()
	defer c.server.store.mu.RUnlock()
	st := c.server.store.state.Cloud
	waiting := len(st.ProbeQueue)
	if waiting > 0 && st.ProbeQueue[0] == c.probeCurrent {
		waiting--
	}
	return map[string]any{
		"busy": c.busyLocked(), "message": c.message,
		"sync_busy": c.busy, "sync_stopping": c.syncStopping,
		"sync_done": c.syncDone, "sync_total": c.syncTotal, "sync_unchanged": c.syncUnchanged,
		"probe_busy": c.probeBusy, "probe_stopping": c.probeStopping,
		"probe_current": c.probeCurrent, "probe_queued": waiting, "probe_message": c.probeMessage,
		"connected": st.Cookie != "", "enabled": st.Settings.Enabled,
	}
}

func (c *Cloud115) progress(w http.ResponseWriter, r *http.Request) {
	jsonResponse(w, 200, c.progressData())
}

func (c *Cloud115) terminate(w http.ResponseWriter, r *http.Request) {
	var body struct{}
	if !decodeBody(w, r, &body) {
		return
	}
	c.mu.Lock()
	if strings.HasSuffix(r.URL.Path, "/sync/stop") {
		if c.busy && c.syncCancel != nil {
			c.syncStopping, c.message = true, "正在终止 STRM 生成…"
			c.syncCancel()
		}
	} else if c.probeBusy && c.probeCancel != nil {
		c.probeStopping, c.probeMessage = true, "正在终止当前探测，未完成队列将保留…"
		c.probeCancel()
	}
	c.mu.Unlock()
	jsonResponse(w, 202, map[string]bool{"accepted": true})
}
