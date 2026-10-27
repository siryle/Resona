package resona

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

type trackMove struct {
	source, destination string
	created             []string
}

// Stage complete files before publishing their new paths in the index.
func (s *Scanner) stageTrackMove(ctx context.Context, source string, t Track) (trackMove, error) {
	move := trackMove{source: source, destination: source}
	root := s.config.LibraryDir
	if t.Library == "cloud" {
		root = filepath.Join(s.config.DataDir, "cloud115", "strm")
	}
	real, err := filepath.EvalSymlinks(source)
	info, statErr := os.Lstat(source)
	if err != nil || statErr != nil || !within(root, real) || !info.Mode().IsRegular() {
		return move, errors.New("source is unavailable or outside its library")
	}
	artist := t.AlbumArtist
	if artist == "" {
		artist = t.Artist
	}
	dir := filepath.Join(root, safeComponent(artist), safeComponent(t.Album))
	if t.Library == "cloud" {
		dir = filepath.Join(dir, t.ID)
		t.Format = "strm"
	}
	dir, err = musicDirectory(root, dir)
	if err != nil {
		return move, err
	}
	if filepath.Join(dir, safeComponent(t.Title+"-"+t.Artist)+"."+t.Format) == source {
		return move, musicPermissions(root, source)
	}
	destination, exists, err := s.trackDestination(ctx, dir, t)
	if err != nil {
		return move, err
	}
	if exists {
		target, err := os.Stat(destination)
		if err == nil && os.SameFile(info, target) {
			return move, musicPermissions(root, source)
		}
	} else {
		if err := os.Link(source, destination); err != nil {
			return move, err
		}
		move.created = append(move.created, destination)
	}
	move.destination = destination
	if err := os.Chmod(destination, 0777); err != nil {
		move.rollback()
		return trackMove{}, err
	}
	sidecar := strings.TrimSuffix(destination, filepath.Ext(destination)) + ".lrc"
	_, sidecarErr := os.Lstat(sidecar)
	if err := s.copyLyrics(source, destination, root); err != nil {
		move.rollback()
		return trackMove{}, err
	}
	if errors.Is(sidecarErr, os.ErrNotExist) {
		move.created = append(move.created, sidecar)
	}
	return move, nil
}

func (m trackMove) rollback() {
	for _, path := range m.created {
		_ = os.Remove(path)
	}
}

func (m trackMove) finish() error {
	if m.source == m.destination {
		return nil
	}
	if err := os.Remove(m.source); err != nil {
		return err
	}
	return removeUnusedLyrics(m.source, m.destination)
}
