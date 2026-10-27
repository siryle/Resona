package resona

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestIndividualJobDetailsAndLightweightList(t *testing.T) {
	s := testServer(t)
	if err := s.store.update(func(st *libraryState) error {
		st.Tracks["song"] = DiskTrack{Track: Track{ID: "song", Duration: 120}}
		st.Jobs = []Job{{ID: "one", Phase: "Finished", State: "completed",
			Errors: []string{"original warning"}, Items: []JobItem{{Filename: "Song.mp3", TrackID: "song", State: "imported"}}}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	token := loginToken(t, s)
	w := request(s.Handler(), "GET", "/api/v1/jobs?summary=1", "", token)
	if w.Code != 200 || strings.Contains(w.Body.String(), "Song.mp3") {
		t.Fatal("summary list still includes every file", w.Code, w.Body.String())
	}
	w = request(s.Handler(), "GET", "/api/v1/jobs/one", "", token)
	var job Job
	if err := json.Unmarshal(w.Body.Bytes(), &job); err != nil || w.Code != 200 ||
		len(job.Items) != 1 || job.Items[0].Duration != 120 || len(job.Errors) != 1 {
		t.Fatal("individual details missing", err, w.Code, w.Body.String())
	}
	job.Items[0].Filename = "changed"
	snapshot, _ := s.store.Job("one")
	snapshot.Errors[0] = "changed"
	current, _ := s.store.Job("one")
	if current.Items[0].Filename != "Song.mp3" || current.Errors[0] != "original warning" {
		t.Fatal("detail response mutated stored history")
	}
	for _, tc := range []struct {
		id, token string
		status    int
	}{
		{"one", "", 401}, {"missing", token, 404},
	} {
		if w := request(s.Handler(), "GET", "/api/v1/jobs/"+tc.id, "", tc.token); w.Code != tc.status {
			t.Fatal("job detail boundary", w.Code)
		}
	}
}
