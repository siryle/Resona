package resona

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/url"
	"strings"
)

func (s *Store) findTrack(query string, args ...any) (Track, bool, error) {
	var data []byte
	if err := s.db.QueryRow(query, args...).Scan(&data); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Track{}, false, nil
		}
		return Track{}, false, err
	}
	var disk DiskTrack
	if err := json.Unmarshal(data, &disk); err != nil {
		return Track{}, false, err
	}
	t := disk.Track
	t.Path = disk.File
	return t, true, nil
}

func trackFilter(query url.Values) (string, []any) {
	where, args := "visible=1", []any{}
	if library := query.Get("library"); library != "" && library != "all" {
		where += " AND library=?"
		args = append(args, library)
	}
	if search := strings.ToLower(strings.TrimSpace(query.Get("search"))); search != "" {
		// Preserve Unicode substring matching, including one-character Chinese searches.
		where += " AND instr(search,?)>0"
		args = append(args, search)
	}
	if query.Get("favorite") == "true" {
		where += " AND favorite=1"
	}
	if album := query.Get("album"); album != "" {
		where += " AND album_id=?"
		args = append(args, album)
	}
	if artist := query.Get("artist"); artist != "" {
		where += " AND (artist=? OR album_artist=?)"
		args = append(args, artist, artist)
	}
	return where, args
}

func (s *Store) queryTracks(ctx context.Context, query url.Values) ([]Track, int, int, int, error) {
	where, args := trackFilter(query)
	offset := parsePositive(query.Get("offset"), 0)
	limit := min(parsePositive(query.Get("limit"), 100), 500)
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, 0, 0, 0, err
	}
	defer tx.Rollback()
	var total int
	if err := tx.QueryRowContext(ctx, "SELECT count(*) FROM tracks WHERE "+where, args...).Scan(&total); err != nil {
		return nil, 0, 0, 0, err
	}
	offset = min(offset, total)
	order := "added_at DESC,id"
	if query.Get("album") != "" {
		order = "disc,number," + order
	}
	rows, err := tx.QueryContext(ctx, "SELECT data FROM tracks WHERE "+where+" ORDER BY "+order+" LIMIT ? OFFSET ?",
		append(args, limit, offset)...)
	if err != nil {
		return nil, 0, 0, 0, err
	}
	defer rows.Close()
	out := []Track{}
	for rows.Next() {
		var data []byte
		if err := rows.Scan(&data); err != nil {
			return nil, 0, 0, 0, err
		}
		var disk DiskTrack
		if err := json.Unmarshal(data, &disk); err != nil {
			return nil, 0, 0, 0, err
		}
		out = append(out, disk.Track)
	}
	return out, total, offset, limit, rows.Err()
}

func (s *Store) queryAlbums(ctx context.Context, query url.Values) ([]Album, error) {
	where, args := trackFilter(query)
	rows, err := s.db.QueryContext(ctx, `WITH filtered AS (
 SELECT *,row_number() OVER (PARTITION BY album_id ORDER BY added_at DESC,id) AS rank,
 first_value(json_extract(data,'$.artwork')) OVER (
 PARTITION BY album_id ORDER BY (coalesce(json_extract(data,'$.artwork'),'')=''),added_at DESC,id) AS cover
 FROM tracks WHERE `+where+`)
 SELECT album_id,max(CASE WHEN rank=1 THEN data END),count(*),sum(duration),max(cover)
 FROM filtered GROUP BY album_id ORDER BY max(added_at) DESC,album_id`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Album{}
	for rows.Next() {
		var album Album
		var data []byte
		var cover sql.NullString
		if err := rows.Scan(&album.ID, &data, &album.Tracks, &album.Duration, &cover); err != nil {
			return nil, err
		}
		var disk DiskTrack
		if err := json.Unmarshal(data, &disk); err != nil {
			return nil, err
		}
		t := disk.Track
		album.Title, album.Artist, album.Year, album.Artwork = t.Album, t.AlbumArtist, t.Year, cover.String
		out = append(out, album)
	}
	return out, rows.Err()
}

type artistSummary struct {
	Name   string `json:"name"`
	Tracks int    `json:"tracks"`
}

func (s *Store) queryArtists(ctx context.Context, query url.Values) ([]artistSummary, error) {
	where, args := trackFilter(query)
	rows, err := s.db.QueryContext(ctx, "SELECT artist,count(*) FROM tracks WHERE "+where+" GROUP BY artist ORDER BY artist", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []artistSummary{}
	for rows.Next() {
		var artist artistSummary
		if err := rows.Scan(&artist.Name, &artist.Tracks); err != nil {
			return nil, err
		}
		out = append(out, artist)
	}
	return out, rows.Err()
}

func (s *Store) queryCloudItems(ctx context.Context, account string, query url.Values) ([]CloudItem, map[string]int, int, int, int, error) {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, nil, 0, 0, 0, err
	}
	defer tx.Rollback()
	counts := map[string]int{}
	rows, err := tx.QueryContext(ctx, "SELECT state,count(*) FROM cloud_items WHERE account=? GROUP BY state", account)
	if err != nil {
		return nil, nil, 0, 0, 0, err
	}
	total := 0
	for rows.Next() {
		var state string
		var count int
		if err := rows.Scan(&state, &count); err != nil {
			rows.Close()
			return nil, nil, 0, 0, 0, err
		}
		counts[state] = count
		total += count
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, nil, 0, 0, 0, err
	}
	if err := rows.Close(); err != nil {
		return nil, nil, 0, 0, 0, err
	}
	where, args := "account=?", []any{account}
	if state := query.Get("state"); state != "" {
		where += " AND state=?"
		args = append(args, state)
		total = counts[state]
	}
	offset := min(parsePositive(query.Get("offset"), 0), total)
	limit := min(parsePositive(query.Get("limit"), 100), 500)
	rows, err = tx.QueryContext(ctx, `SELECT cloud_items.data,probe_queue.track_id IS NOT NULL
FROM cloud_items LEFT JOIN probe_queue ON cloud_items.id=probe_queue.track_id
WHERE `+where+" ORDER BY path,id LIMIT ? OFFSET ?", append(args, limit, offset)...)
	if err != nil {
		return nil, nil, 0, 0, 0, err
	}
	defer rows.Close()
	items := []CloudItem{}
	for rows.Next() {
		var data []byte
		var queued bool
		if err := rows.Scan(&data, &queued); err != nil {
			return nil, nil, 0, 0, 0, err
		}
		var item CloudItem
		if err := json.Unmarshal(data, &item); err != nil {
			return nil, nil, 0, 0, 0, err
		}
		item.Queued = queued
		items = append(items, item)
	}
	return items, counts, total, offset, limit, rows.Err()
}
