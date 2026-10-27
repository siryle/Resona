package resona

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
)

func removeCloudTracks(st *libraryState, ids map[string]bool) {
	for id := range ids {
		delete(st.Tracks, id)
		delete(st.Cloud.Items, id)
	}
	st.Cloud.ProbeQueue = slices.DeleteFunc(st.Cloud.ProbeQueue, func(id string) bool { return ids[id] })
}

func (c *Cloud115) missingSTRM(path string) bool {
	if !within(filepath.Join(c.server.config.DataDir, "cloud115", "strm"), path) {
		return false
	}
	_, err := os.Stat(path)
	return errors.Is(err, os.ErrNotExist)
}

// Called with dataMu held so generation and probe publication cannot recreate deleted entries.
func (c *Cloud115) pruneSTRMFiles(files map[string]string) error {
	for id, path := range files {
		if !c.missingSTRM(path) {
			delete(files, id)
		}
	}
	if len(files) == 0 {
		return nil
	}
	return c.server.store.updateCloud(func(st *libraryState) error {
		removed := make(map[string]bool)
		for id, path := range files {
			if disk, ok := st.Tracks[id]; ok && disk.Remote != nil && disk.File == path && c.missingSTRM(path) {
				removed[id] = true
			}
		}
		removeCloudTracks(st, removed)
		return nil
	})
}

func (c *Cloud115) pruneMissingSTRMs() error {
	if !c.dataMu.TryLock() {
		return nil
	}
	defer c.dataMu.Unlock()
	files := make(map[string]string)
	c.server.store.mu.RLock()
	for id, disk := range c.server.store.state.Tracks {
		if disk.Remote != nil {
			files[id] = disk.File
		}
	}
	c.server.store.mu.RUnlock()
	return c.pruneSTRMFiles(files)
}

func (c *Cloud115) pruneProbeSTRM(id string) error {
	c.server.store.mu.RLock()
	disk := c.server.store.state.Tracks[id]
	c.server.store.mu.RUnlock()
	if disk.Remote == nil {
		return nil
	}
	return c.pruneSTRMFiles(map[string]string{id: disk.File})
}
