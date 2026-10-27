package resona

import (
	"bytes"
	"crypto/sha256"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func TestSessionsSurviveRestartAndPersistRevocation(t *testing.T) {
	s := testServer(t)
	token := loginToken(t, s)
	data, err := os.ReadFile(s.auth.sessionPath())
	if err != nil || bytes.Contains(data, []byte(token)) || bytes.Contains(data, []byte("a-test-password-123")) {
		t.Fatal("session persistence exposed credentials", err)
	}
	if info, err := os.Stat(s.auth.sessionPath()); err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("saved sessions must be private")
	}
	r := httptest.NewRequest("GET", "/", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	restarted, err := NewAuth(s.config)
	if err != nil || !restarted.valid(r) {
		t.Fatal("session lost after server restart", err)
	}
	cookie := httptest.NewRequest("GET", "/", nil)
	cookie.Header.Set("Cookie", "resona_session="+token)
	if !restarted.valid(cookie) {
		t.Fatal("browser cookie lost after restart")
	}
	if err := restarted.logout(httptest.NewRecorder(), r); err != nil {
		t.Fatal(err)
	}
	restarted, err = NewAuth(s.config)
	if err != nil || restarted.valid(r) {
		t.Fatal("revoked session restored", err)
	}
}

func TestPersistedSessionsRejectExpiryAndChangedCredentials(t *testing.T) {
	s := testServer(t)
	token := loginToken(t, s)
	r := httptest.NewRequest("GET", "/", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	key := sha256.Sum256([]byte(token))
	s.auth.sessions[key] = session{Expires: time.Now().Add(-time.Minute)}
	if err := s.auth.saveSessions(); err != nil {
		t.Fatal(err)
	}
	restarted, err := NewAuth(s.config)
	if err != nil || restarted.valid(r) {
		t.Fatal("expired session restored", err)
	}
	s.auth.sessions[key] = session{Expires: time.Now().Add(time.Hour)}
	s.auth.hash = secureRandom(32)
	if err := s.auth.saveSessions(); err != nil {
		t.Fatal(err)
	}
	restarted, err = NewAuth(s.config)
	if err != nil || restarted.valid(r) {
		t.Fatal("session from different credentials restored", err)
	}
}

func TestSessionPersistenceFailureDoesNotIssueOrRevokeToken(t *testing.T) {
	s := testServer(t)
	token := loginToken(t, s)
	if err := os.Remove(s.auth.sessionPath()); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(s.auth.sessionPath(), 0700); err != nil {
		t.Fatal(err)
	}
	w := request(s.Handler(), "POST", "/api/v1/auth/login",
		`{"username":"admin","password":"a-test-password-123"}`, "")
	if w.Code != 500 {
		t.Fatal("session write failure reported as credentials error", w.Code)
	}
	w = request(s.Handler(), "POST", "/api/v1/auth/logout", "{}", token)
	if w.Code != 500 {
		t.Fatal("failed revocation reported as success", w.Code)
	}
	if w = request(s.Handler(), "GET", "/api/v1/tracks", "", token); w.Code != 200 {
		t.Fatal("failed logout partially revoked session", w.Code)
	}
}
