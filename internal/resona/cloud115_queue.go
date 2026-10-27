package resona

import (
	"context"
	"errors"
	"sort"
	"time"
)

// enqueue runs with mu held; the durable head stays in the queue until publication finishes.
func (c *Cloud115) enqueue(mode, trackID string) error {
	return c.server.store.updateCloud(func(st *libraryState) error {
		if mode != "resume" {
			st.Cloud.ProbePaused = false
		}
		queued := make(map[string]bool, len(st.Cloud.ProbeQueue))
		for _, id := range st.Cloud.ProbeQueue {
			queued[id] = true
		}
		if trackID != "" {
			item, ok := st.Cloud.Items[trackID]
			if !ok || item.Account != st.Cloud.Account || item.State == "missing" {
				return errors.New("歌曲不存在或来源已失效")
			}
		}
		var ids []string
		for id, item := range st.Cloud.Items {
			if queued[id] || item.Account != st.Cloud.Account || item.State == "missing" {
				continue
			}
			if trackID != "" {
				if id != trackID {
					continue
				}
			} else if mode == "retry" {
				if item.State != "failed" {
					continue
				}
			} else if mode == "resume" {
				// Migrate an interrupted probe from versions without an explicit queue.
				if item.State != "probing" {
					continue
				}
			} else if item.State != "pending" && item.State != "probing" {
				continue
			}
			ids = append(ids, id)
		}
		sort.Slice(ids, func(i, j int) bool {
			a, b := st.Cloud.Items[ids[i]], st.Cloud.Items[ids[j]]
			if a.Path == b.Path {
				return ids[i] < ids[j]
			}
			return a.Path < b.Path
		})
		for _, id := range ids {
			item := st.Cloud.Items[id]
			item.State, item.Error = "pending", ""
			st.Cloud.Items[id] = item
		}
		st.Cloud.ProbeQueue = append(st.Cloud.ProbeQueue, ids...)
		return nil
	})
}

func (c *Cloud115) sameItem(item CloudItem) bool {
	c.server.store.mu.RLock()
	defer c.server.store.mu.RUnlock()
	state := c.server.store.state.Cloud
	current, ok := state.Items[item.TrackID]
	return ok && state.Account == item.Account && current.State != "missing" &&
		current.Fingerprint == item.Fingerprint && current.RemoteFile == item.RemoteFile &&
		current.Name == item.Name && current.Path == item.Path
}

func (c *Cloud115) dequeue(id string) error {
	return c.server.store.updateCloud(func(st *libraryState) error {
		if len(st.Cloud.ProbeQueue) > 0 && st.Cloud.ProbeQueue[0] == id {
			st.Cloud.ProbeQueue = st.Cloud.ProbeQueue[1:]
		}
		return nil
	})
}

func (c *Cloud115) probeWorker(ctx context.Context) {
	defer c.wg.Done()
	var err error
	for {
		c.mu.Lock()
		state := c.snapshot()
		if err != nil || ctx.Err() != nil || !state.Settings.Enabled || state.Cookie == "" || len(state.ProbeQueue) == 0 {
			if c.probeStopping {
				c.mu.Unlock()
				saveErr := c.server.store.updateCloud(func(st *libraryState) error { st.Cloud.ProbePaused = true; return nil })
				c.mu.Lock()
				if saveErr != nil {
					err = saveErr
				}
			}
			c.probeBusy, c.probeStopping, c.probeCurrent = false, false, ""
			switch {
			case err != nil && !errors.Is(err, context.Canceled):
				c.probeMessage = err.Error()
			case ctx.Err() != nil:
				c.probeMessage = "预探测已暂停，未完成队列已保留"
			case err != nil:
				c.probeMessage = err.Error()
			case len(state.ProbeQueue) == 0:
				c.probeMessage = "预探测队列已完成"
			default:
				c.probeMessage = "预探测已暂停，未完成队列已保留"
			}
			paused := ctx.Err() != nil || len(state.ProbeQueue) > 0
			if c.probeCancel != nil {
				c.probeCancel()
				c.probeCancel = nil
			}
			c.mu.Unlock()
			logger := c.server.logger.With("category", "probe")
			if err != nil && !errors.Is(err, context.Canceled) {
				logger.Warn("115 预探测队列已暂停", "reason", err, "remaining", len(state.ProbeQueue))
			} else {
				logger.Info("115 预探测任务结束", "remaining", len(state.ProbeQueue), "paused", paused)
			}
			return
		}
		id := state.ProbeQueue[0]
		c.probeCurrent = id
		c.probeMessage = "正在探测：" + state.Items[id].Name
		c.mu.Unlock()
		err = c.probeNext(ctx, id)
	}
}

func (c *Cloud115) probeNext(ctx context.Context, id string) error {
	c.dataMu.Lock()
	if err := c.pruneProbeSTRM(id); err != nil {
		c.dataMu.Unlock()
		return err
	}
	state := c.snapshot()
	item, ok := state.Items[id]
	if !ok || item.Account != state.Account || item.State == "missing" || item.State == "skipped" || item.State == "ready" {
		// Ready/skipped can be durable results from a crash just before dequeue.
		// Explicit reprobes are marked pending when queued.
		err := c.dequeue(id)
		c.dataMu.Unlock()
		return err
	}
	if err := ctx.Err(); err != nil {
		c.dataMu.Unlock()
		return err
	}
	if err := c.setItemState(id, "probing", ""); err != nil {
		c.dataMu.Unlock()
		return err
	}
	if err := c.writeSTRM(item); err != nil {
		c.server.logger.With("category", "probe").Warn("115 歌曲预探测失败，无法写入 STRM", "file", item.Path, "reason", err)
		err = c.finishProbe(item, Track{}, errors.New("无法写入 STRM，请检查数据目录权限"))
		c.dataMu.Unlock()
		return err
	}
	c.dataMu.Unlock()
	started := time.Now()
	c.server.logger.With("category", "probe").Info("115 开始预探测歌曲", "file", item.Path, "track", id)
	probeCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	track, probeErr := c.probe(probeCtx, item)
	if probeErr == nil && probeCtx.Err() != nil {
		probeErr = probeCtx.Err()
	}
	cancel()
	c.dataMu.Lock()
	defer c.dataMu.Unlock()
	if err := c.pruneProbeSTRM(id); err != nil {
		return err
	}
	if ctx.Err() != nil {
		c.server.logger.With("category", "probe").Info("115 歌曲预探测已终止", "file", item.Path)
		if c.sameItem(item) {
			if err := c.setItemState(id, "pending", ""); err != nil {
				return err
			}
		}
		return ctx.Err()
	}
	if !c.sameItem(item) {
		c.server.logger.With("category", "probe").Info("115 歌曲预探测结果已跳过，文件索引已变化", "file", item.Path)
		// A concurrent sync changed or removed this file. Re-read the queue head.
		return nil
	}
	err := c.finishProbe(item, track, probeErr)
	logger := c.server.logger.With("category", "probe")
	if probeErr != nil || err != nil {
		logger.Warn("115 歌曲预探测失败", "file", item.Path, "reason", errors.Join(probeErr, err), "elapsed", time.Since(started))
	} else {
		c.server.store.mu.RLock()
		result := c.server.store.state.Cloud.Items[id].State
		c.server.store.mu.RUnlock()
		logger.Info("115 歌曲预探测完成", "file", item.Path, "state", result, "elapsed", time.Since(started))
	}
	return err
}

func (c *Cloud115) finishProbe(item CloudItem, track Track, probeErr error) error {
	if probeErr != nil {
		if err := c.setItemState(item.TrackID, "failed", probeErr.Error()); err != nil {
			return err
		}
		if errors.Is(probeErr, errCloudAuth) || cloudRestricted(probeErr) {
			return probeErr
		}
	} else if err := c.publish(item, track); err != nil {
		return err
	}
	if err := c.server.ctx.Err(); err != nil {
		return err
	}
	// Cache a failed attempt as failed, then move on; persistence errors keep the head.
	return c.dequeue(item.TrackID)
}
