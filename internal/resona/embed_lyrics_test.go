package resona

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func taggedAudioFixture(t *testing.T, s *Server, format, embedded string, cover bool) Track {
	t.Helper()
	path := filepath.Join(s.config.LibraryDir, "Song-Artist."+format)
	args := []string{"-v", "error", "-f", "lavfi", "-i", "sine=duration=0.3"}
	if cover {
		pic := filepath.Join(s.config.DataDir, "fixture.png")
		im := image.NewRGBA(image.Rect(0, 0, 32, 32))
		im.Set(0, 0, color.RGBA{R: 255, A: 255})
		f, err := os.Create(pic)
		if err != nil {
			t.Fatal(err)
		}
		if err := png.Encode(f, im); err != nil {
			t.Fatal(err)
		}
		f.Close()
		args = append(args, "-i", pic, "-map", "0:a", "-map", "1:v", "-c:v", "copy", "-disposition:v", "attached_pic")
	}
	args = append(args, "-metadata", "title=Song", "-metadata", "artist=Artist", "-metadata", "album=Album",
		"-metadata", "genre=Original", "-metadata", "comment=Preserve me", "-metadata", "lyrics="+embedded, path)
	if out, err := exec.Command("ffmpeg", args...).CombinedOutput(); err != nil {
		t.Fatal(err, string(out))
	}
	track, err := readMetadata(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	track.ID, track.Size, err = hashFile(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	track.Path, track.Favorite, track.MetadataLocked, track.AddedAt = path, true, true, time.Now().UTC()
	if cover {
		track.Artwork = s.scanner.extractArtwork(context.Background(), path, track.ID)
		if track.Artwork == "" {
			t.Fatal("artwork not indexed")
		}
	}
	lyrics, _ := makeLyrics(embedded, "embedded")
	if err := s.store.update(func(st *libraryState) error {
		st.Tracks[track.ID] = DiskTrack{Track: track, File: path, EmbeddedLyrics: lyrics, EmbeddedChecked: true}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return track
}

func streamDigest(t *testing.T, path, stream string) []byte {
	t.Helper()
	out, err := exec.Command("ffmpeg", "-v", "error", "-i", path, "-map", stream, "-f", "hash", "-hash", "sha256", "-").CombinedOutput()
	if err != nil {
		t.Fatal(err, string(out))
	}
	return out
}

func TestEmbedLyricsRealFormats(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("requires ffmpeg")
	}
	for _, format := range []string{"mp3", "flac", "m4a", "ogg", "opus"} {
		t.Run(format, func(t *testing.T) {
			s := testServer(t)
			hasCover := format == "mp3" || format == "flac" || format == "m4a"
			oldLyrics := ""
			if format == "m4a" {
				oldLyrics = "[00:00.01]Old"
			}
			track := taggedAudioFixture(t, s, format, oldLyrics, hasCover)
			audioDigest := streamDigest(t, track.Path, "0:a:0")
			var coverDigest []byte
			if hasCover {
				coverDigest = streamDigest(t, track.Path, "0:v:0")
			}
			original, _ := os.ReadFile(track.Path)
			inbox := filepath.Join(s.config.InboxDir, "original."+format)
			if err := os.WriteFile(inbox, original, 0640); err != nil {
				t.Fatal(err)
			}
			text := "[00:00.01]LRC = # ; \\ line\n[00:00.02]歌词 second line"
			if format == "flac" {
				text += "\n" + strings.Repeat("large lyric line ", 10000)
			}
			text = strings.TrimSpace(text)
			lyrics, _ := makeLyrics(text, "qq")
			if format == "mp3" || format == "opus" {
				if err := os.WriteFile(strings.TrimSuffix(track.Path, filepath.Ext(track.Path))+".lrc", []byte(text), 0640); err != nil {
					t.Fatal(err)
				}
			} else if err := s.store.update(func(st *libraryState) error {
				d := st.Tracks[track.ID]
				d.Lyrics = lyrics
				st.Tracks[track.ID] = d
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			if err := s.store.putJob(Job{ID: "history", State: "completed", Items: []JobItem{{TrackID: track.ID}}}); err != nil {
				t.Fatal(err)
			}
			h, token := s.Handler(), loginToken(t, s)
			endpoint := "/api/v1/tracks/" + track.ID + "/lyrics/embed"
			if w := request(h, "POST", endpoint, `{}`, ""); w.Code != 401 {
				t.Fatal("unauthenticated retag", w.Code)
			}
			if oldLyrics != "" {
				if w := request(h, "POST", endpoint, `{}`, token); w.Code != 409 {
					t.Fatal("implicit overwrite", w.Code, w.Body.String())
				}
			}
			w := request(h, "POST", endpoint, `{"replace":true}`, token)
			var updated Track
			if err := json.Unmarshal(w.Body.Bytes(), &updated); err != nil || w.Code != 200 {
				t.Fatal(w.Code, w.Body.String(), err)
			}
			if updated.HasEmbeddedLyrics == nil || !*updated.HasEmbeddedLyrics || updated.ID == track.ID || !updated.Favorite || !updated.MetadataLocked || !updated.AddedAt.Equal(track.AddedAt) {
				t.Fatal("retagged identity/state incorrect", updated)
			}
			current, ok := s.store.Track(updated.ID)
			if !ok {
				t.Fatal("retagged file not indexed")
			}
			if current.Path != track.Path {
				t.Fatal("tag-only write renamed the recording", current.Path, track.Path)
			}
			id, size, err := hashFile(context.Background(), current.Path)
			if err != nil || id != updated.ID || size != updated.Size {
				t.Fatal("download hash contract broken", err)
			}
			metadata, err := readMetadata(context.Background(), current.Path)
			if err != nil || metadata.TagLyrics != text || metadata.Title != "Song" || metadata.Artist != "Artist" || metadata.Album != "Album" || metadata.Genre != "Original" {
				t.Fatal("tags lost", len(metadata.TagLyrics), len(text), metadata.Title, metadata.Artist, metadata.Album, metadata.Genre, err)
			}
			if !bytes.Equal(audioDigest, streamDigest(t, current.Path, "0:a:0")) {
				t.Fatal("audio changed")
			}
			if hasCover && !bytes.Equal(coverDigest, streamDigest(t, current.Path, "0:v:0")) {
				t.Fatal("embedded cover changed")
			}
			if hasCover && request(h, "GET", "/api/v1/tracks/"+updated.ID+"/cover", "", token).Code != 200 {
				t.Fatal("cover endpoint lost")
			}
			if data, _ := os.ReadFile(inbox); !bytes.Equal(data, original) {
				t.Fatal("source import modified")
			}
			if s.store.Jobs()[0].Items[0].TrackID != updated.ID {
				t.Fatal("history references not migrated")
			}
			if _, ok := s.store.Track(track.ID); ok {
				t.Fatal("old ID still serves changed content")
			}
			reopened, err := OpenStore(s.config.DataDir)
			if err != nil || len(reopened.Tracks()) != 1 {
				t.Fatal("retagging not persisted", err)
			}
			// Both regular and rescrape scans retain tags and skip the unchanged original import.
			for _, rescrape := range []bool{false, true} {
				if _, err := s.scanner.Start(context.Background(), rescrape); err != nil {
					t.Fatal(err)
				}
				s.scanner.Wait()
				tracks := s.store.Tracks()
				if len(tracks) != 1 || tracks[0].ID != updated.ID || tracks[0].HasEmbeddedLyrics == nil || !*tracks[0].HasEmbeddedLyrics {
					t.Fatal("rescan duplicated or discarded retagged song", tracks, s.store.Jobs())
				}
			}
		})
	}
}

func TestEmbedLyricsBoundariesAndRollback(t *testing.T) {
	s := testServer(t)
	track := taggedAudioFixture(t, s, "mp3", "", false)
	h, token := s.Handler(), loginToken(t, s)
	endpoint := "/api/v1/tracks/" + track.ID + "/lyrics/embed"
	if w := request(h, "POST", endpoint, `{}`, token); w.Code != 404 {
		t.Fatal("empty lyrics retag", w.Code)
	}
	r := httptest.NewRequest("POST", endpoint, strings.NewReader(`{}`))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Origin", "https://other.example")
	r.AddCookie(&http.Cookie{Name: "resona_session", Value: token})
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("cross-origin retag allowed")
	}
	if err := s.store.update(func(st *libraryState) error {
		d := st.Tracks[track.ID]
		d.Lyrics, _ = makeLyrics("[00:00.01]New", "qq")
		st.Tracks[track.ID] = d
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for _, active := range []bool{true, false} {
		s.scanner.mu.Lock()
		s.scanner.active, s.scanner.editing = active, !active
		s.scanner.mu.Unlock()
		if w := request(h, "POST", endpoint, `{}`, token); w.Code != 409 {
			t.Fatal("concurrent mutation permitted", w.Code)
		}
	}
	s.scanner.mu.Lock()
	s.scanner.active, s.scanner.editing = false, false
	s.scanner.mu.Unlock()
	before, _ := os.ReadFile(track.Path)
	// A failed index commit must leave the original indexed audio and bytes intact.
	s.store.path = filepath.Join(s.config.DataDir, "missing", "library.json")
	if _, err := s.embedTrackLyrics(context.Background(), track.ID, false); err == nil {
		t.Fatal("failed persistence accepted")
	}
	if after, _ := os.ReadFile(track.Path); !bytes.Equal(before, after) {
		t.Fatal("rollback lost original audio")
	}
	if len(s.store.Tracks()) != 1 || s.store.Tracks()[0].ID != track.ID {
		t.Fatal("rollback mutated index")
	}
	entries, _ := os.ReadDir(s.config.LibraryDir)
	if len(entries) != 1 {
		t.Fatal("rollback leaked staged files", entries)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := s.embedTrackLyrics(ctx, track.ID, false); !errors.Is(err, errTrackChanged) && !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation ignored", err)
	}
}

func TestMP3LyricsExcludeUnsupportedExtraStreams(t *testing.T) {
	s := testServer(t)
	track := taggedAudioFixture(t, s, "mp3", "", false)
	extra := filepath.Join(s.config.DataDir, "attachment.bin")
	if err := os.WriteFile(extra, []byte("non-audio attachment"), 0600); err != nil {
		t.Fatal(err)
	}
	wrapped := filepath.Join(s.config.DataDir, "wrapped.mp3")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-y", "-i", track.Path, "-map", "0:a",
		"-c", "copy", "-attach", extra, "-metadata:s:t", "mimetype=application/octet-stream",
		"-f", "matroska", wrapped).CombinedOutput(); err != nil {
		t.Fatal(err, string(out))
	}
	if err := os.Rename(wrapped, track.Path); err != nil {
		t.Fatal(err)
	}
	packetDigest := func(path string) []byte {
		t.Helper()
		out, err := exec.Command("ffmpeg", "-v", "error", "-i", path, "-map", "0:a:0",
			"-c", "copy", "-f", "hash", "-hash", "sha256", "-").CombinedOutput()
		if err != nil {
			t.Fatal(err, string(out))
		}
		return out
	}
	digest := packetDigest(track.Path)
	old := track.ID
	track.ID, track.Size, _ = hashFile(context.Background(), track.Path)
	if err := s.store.update(func(st *libraryState) error {
		delete(st.Tracks, old)
		lyric, _ := makeLyrics("[00:00.01]MP3 lyric", "test")
		st.Tracks[track.ID] = DiskTrack{Track: track, File: track.Path, Lyrics: lyric}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	updated, err := s.embedTrackLyrics(context.Background(), track.ID, false)
	if err != nil {
		t.Fatal("MP3 with extra stream still failed to remux", err)
	}
	current, _ := s.store.Track(updated.ID)
	if !bytes.Equal(digest, packetDigest(current.Path)) {
		t.Fatal("MP3 audio was re-encoded")
	}
	if metadata, err := readMetadata(context.Background(), current.Path); err != nil || metadata.TagLyrics != "[00:00.01]MP3 lyric" {
		t.Fatal("MP3 lyrics missing", err)
	}
}

func TestEmbeddedLyricsBadgesSeparateSidecarsAndCaches(t *testing.T) {
	s := testServer(t)
	track := taggedAudioFixture(t, s, "mp3", "", false)
	if err := s.store.update(func(st *libraryState) error {
		d := st.Tracks[track.ID]
		d.EmbeddedChecked = false
		d.Lyrics, _ = makeLyrics("cached", "qq")
		st.Tracks[track.ID] = d
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(strings.TrimSuffix(track.Path, ".mp3")+".lrc", []byte("[00:00.01]External"), 0600); err != nil {
		t.Fatal(err)
	}
	h, token := s.Handler(), loginToken(t, s)
	var result Track
	w := request(h, "GET", "/api/v1/tracks/"+track.ID+"?check_lyrics=true", "", token)
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || result.HasEmbeddedLyrics == nil || *result.HasEmbeddedLyrics || !result.HasLRCLyrics {
		t.Fatal("external lyrics falsely reported as embedded", w.Body.String(), err)
	}
	list := request(h, "GET", "/api/v1/tracks", "", token)
	if !strings.Contains(list.Body.String(), `"has_embedded_lyrics":false`) || !strings.Contains(list.Body.String(), `"has_lrc_lyrics":true`) {
		t.Fatal("badge missing from list", list.Body.String())
	}
}
