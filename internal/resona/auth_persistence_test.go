package resona

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
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

func requestCookie(h http.Handler, method, path, body, token string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.AddCookie(&http.Cookie{Name: "resona_session", Value: token})
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestSessionAutoRenewsOnActivityAndRefreshesCookie(t *testing.T) {
	s := testServer(t)
	now := time.Now().Truncate(time.Second)
	s.auth.clock = func() time.Time { return now }
	h := s.Handler()

	w := request(h, "POST", "/api/v1/auth/login", `{"username":"admin","password":"a-test-password-123"}`, "")
	if w.Code != 200 {
		t.Fatalf("login failed: %d %s", w.Code, w.Body.String())
	}
	var loginBody struct {
		Token     string `json:"token"`
		Username  string `json:"username"`
		ExpiresIn int64  `json:"expires_in"`
		ExpiresAt string `json:"expires_at"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &loginBody); err != nil {
		t.Fatal(err)
	}
	if len(loginBody.Token) != 64 || loginBody.ExpiresIn != 31536000 {
		t.Fatalf("unexpected login response: %+v", loginBody)
	}
	parsedAt, err := time.Parse(time.RFC3339, loginBody.ExpiresAt)
	if err != nil || !parsedAt.Equal(now.Add(sessionTTL).UTC()) {
		t.Fatalf("unexpected expires_at: %q err=%v", loginBody.ExpiresAt, err)
	}
	token := loginBody.Token

	beforeDisk, err := os.ReadFile(s.auth.sessionPath())
	if err != nil {
		t.Fatal(err)
	}

	// Within the 24h renewal cooldown, activity must not rewrite sessions.json or emit Set-Cookie.
	now = now.Add(2 * time.Hour)
	w = requestCookie(h, "GET", "/api/v1/tracks", "", token)
	if w.Code != 200 {
		t.Fatalf("cookie tracks failed: %d", w.Code)
	}
	if len(w.Result().Cookies()) != 0 {
		t.Fatalf("unexpected Set-Cookie within cooldown: %v", w.Result().Cookies())
	}
	afterCooldownDisk, err := os.ReadFile(s.auth.sessionPath())
	if err != nil || !bytes.Equal(beforeDisk, afterCooldownDisk) {
		t.Fatalf("sessions.json rewritten within cooldown: err=%v", err)
	}

	// After 25h, cookie activity slides expiry to now+365d, persists it, and re-issues Set-Cookie.
	now = now.Add(23 * time.Hour)
	w = requestCookie(h, "GET", "/api/v1/tracks", "", token)
	if w.Code != 200 {
		t.Fatalf("cookie renewal request failed: %d", w.Code)
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != "resona_session" || cookies[0].Value != token ||
		cookies[0].MaxAge != 31536000 || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatalf("expected refreshed session cookie, got %+v", cookies)
	}
	expiry, ok := s.auth.tokenExpiry(token)
	if !ok || !expiry.Equal(now.Add(sessionTTL)) {
		t.Fatalf("expected expiry %v, got %v (ok=%v)", now.Add(sessionTTL), expiry, ok)
	}
	restarted, err := NewAuth(s.config)
	if err != nil {
		t.Fatal(err)
	}
	restarted.clock = s.auth.clock
	if restoredExp, ok := restarted.tokenExpiry(token); !ok || !restoredExp.Equal(now.Add(sessionTTL)) {
		t.Fatalf("persisted renewed expiry mismatch: got %v (ok=%v)", restoredExp, ok)
	}

	// After another 25h, Bearer activity extends & persists expiry without emitting Set-Cookie.
	now = now.Add(25 * time.Hour)
	w = request(h, "GET", "/api/v1/tracks", "", token)
	if w.Code != 200 {
		t.Fatalf("bearer renewal request failed: %d", w.Code)
	}
	if len(w.Result().Cookies()) != 0 {
		t.Fatalf("bearer request emitted Set-Cookie: %+v", w.Result().Cookies())
	}
	if expiry, ok := s.auth.tokenExpiry(token); !ok || !expiry.Equal(now.Add(sessionTTL)) {
		t.Fatalf("expected bearer expiry %v, got %v (ok=%v)", now.Add(sessionTTL), expiry, ok)
	}

	// A legacy 7-day persisted session is upgraded immediately on its first authenticated request.
	legacyToken := randomID(32)
	legacyKey := sha256.Sum256([]byte(legacyToken))
	now = time.Now().Truncate(time.Second)
	s.auth.mu.Lock()
	s.auth.sessions[legacyKey] = session{Expires: now.Add(2 * 24 * time.Hour)}
	if err := s.auth.saveSessions(); err != nil {
		s.auth.mu.Unlock()
		t.Fatal(err)
	}
	s.auth.mu.Unlock()

	reloaded, err := NewAuth(s.config)
	if err != nil {
		t.Fatal(err)
	}
	reloaded.clock = func() time.Time { return now }
	s.auth = reloaded
	w = requestCookie(h, "GET", "/api/v1/tracks", "", legacyToken)
	if w.Code != 200 {
		t.Fatalf("legacy session failed: %d", w.Code)
	}
	if cookies := w.Result().Cookies(); len(cookies) != 1 || cookies[0].MaxAge != 31536000 {
		t.Fatalf("legacy session did not receive refreshed cookie: %+v", cookies)
	}
	if expiry, ok := s.auth.tokenExpiry(legacyToken); !ok || !expiry.Equal(now.Add(sessionTTL)) {
		t.Fatalf("legacy session not extended to 365d: %v (ok=%v)", expiry, ok)
	}
}

func TestSessionRefreshEndpointAndFailureHandling(t *testing.T) {
	s := testServer(t)
	now := time.Now().Truncate(time.Second)
	s.auth.clock = func() time.Time { return now }
	h := s.Handler()

	if w := request(h, "POST", "/api/v1/auth/refresh", "{}", ""); w.Code != 401 {
		t.Fatalf("unauthenticated refresh returned %d", w.Code)
	}

	token := loginToken(t, s)

	r := httptest.NewRequest("POST", "/api/v1/auth/refresh", strings.NewReader("{}"))
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 415 {
		t.Fatalf("non-JSON refresh returned %d", w.Code)
	}

	if w := request(h, "POST", "/api/v1/auth/refresh", `{"unknown":true}`, token); w.Code != 400 {
		t.Fatalf("unknown fields returned %d", w.Code)
	}

	r = httptest.NewRequest("POST", "/api/v1/auth/refresh", strings.NewReader("{}"))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Origin", "https://attacker.example")
	r.Header.Set("Authorization", "Bearer "+token)
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatalf("cross-origin refresh returned %d", w.Code)
	}

	now = now.Add(10 * time.Minute)
	w = request(h, "POST", "/api/v1/auth/refresh", "{}", token)
	if w.Code != 200 || len(w.Result().Cookies()) != 0 {
		t.Fatalf("bearer refresh unexpected: code=%d cookies=%+v body=%s", w.Code, w.Result().Cookies(), w.Body.String())
	}
	var payload struct {
		Username  string `json:"username"`
		ExpiresIn int64  `json:"expires_in"`
		ExpiresAt string `json:"expires_at"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Username != "admin" || payload.ExpiresIn != 31536000 || payload.ExpiresAt != now.Add(sessionTTL).UTC().Format(time.RFC3339) {
		t.Fatalf("unexpected refresh payload: %+v", payload)
	}

	now = now.Add(10 * time.Minute)
	w = requestCookie(h, "POST", "/api/v1/auth/refresh", "{}", token)
	if w.Code != 200 {
		t.Fatalf("cookie refresh failed: %d %s", w.Code, w.Body.String())
	}
	if cookies := w.Result().Cookies(); len(cookies) != 1 || cookies[0].MaxAge != 31536000 ||
		!cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatalf("cookie refresh did not re-issue cookie: %+v", cookies)
	}
	restarted, err := NewAuth(s.config)
	if err != nil {
		t.Fatal(err)
	}
	restarted.clock = s.auth.clock
	if restoredExp, ok := restarted.tokenExpiry(token); !ok || !restoredExp.Equal(now.Add(sessionTTL)) {
		t.Fatalf("refreshed session not persisted across restart: %v (ok=%v)", restoredExp, ok)
	}

	w = request(h, "GET", "/api/v1/auth/session", "", token)
	if w.Code != 200 {
		t.Fatalf("session info failed: %d", w.Code)
	}
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Username != "admin" || payload.ExpiresIn <= 0 || payload.ExpiresAt == "" {
		t.Fatalf("unexpected session payload: %+v", payload)
	}

	// Simulate unwritable sessions.json after advancing past both passive and explicit thresholds.
	beforeFailExp, ok := s.auth.tokenExpiry(token)
	if !ok {
		t.Fatal("missing token before disk failure test")
	}
	now = now.Add(25 * time.Hour)
	if err := os.Remove(s.auth.sessionPath()); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(s.auth.sessionPath(), 0700); err != nil {
		t.Fatal(err)
	}
	w = requestCookie(h, "GET", "/api/v1/tracks", "", token)
	if w.Code != 200 || len(w.Result().Cookies()) != 0 {
		t.Fatalf("passive renewal failure broke request or set cookie: code=%d cookies=%+v", w.Code, w.Result().Cookies())
	}
	if afterExp, ok := s.auth.tokenExpiry(token); !ok || !afterExp.Equal(beforeFailExp) {
		t.Fatalf("passive renewal failure mutated in-memory expiry: got %v want %v", afterExp, beforeFailExp)
	}
	w = request(h, "POST", "/api/v1/auth/refresh", "{}", token)
	if w.Code != 500 {
		t.Fatalf("explicit refresh failure returned %d, want 500", w.Code)
	}
	if afterExp, ok := s.auth.tokenExpiry(token); !ok || !afterExp.Equal(beforeFailExp) {
		t.Fatalf("explicit refresh failure mutated in-memory expiry: got %v want %v", afterExp, beforeFailExp)
	}

	if err := os.Remove(s.auth.sessionPath()); err != nil {
		t.Fatal(err)
	}
	s.auth.mu.Lock()
	err = s.auth.saveSessions()
	s.auth.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if w := request(h, "POST", "/api/v1/auth/logout", "{}", token); w.Code != 200 {
		t.Fatalf("logout failed: %d", w.Code)
	}
	if w := request(h, "POST", "/api/v1/auth/refresh", "{}", token); w.Code != 401 {
		t.Fatalf("revoked token refreshed with status %d", w.Code)
	}
}

func TestSessionCapEvictsStalestSessionAndRollsBackOnError(t *testing.T) {
	s := testServer(t)
	now := time.Now().Truncate(time.Second)
	s.auth.clock = func() time.Time { return now }
	h := s.Handler()

	stalestToken := randomID(32)
	secondStalestToken := randomID(32)
	activeToken := randomID(32)

	s.auth.mu.Lock()
	s.auth.sessions[sha256.Sum256([]byte(stalestToken))] = session{Expires: now.Add(time.Hour)}
	s.auth.sessions[sha256.Sum256([]byte(secondStalestToken))] = session{Expires: now.Add(2 * time.Hour)}
	s.auth.sessions[sha256.Sum256([]byte(activeToken))] = session{Expires: now.Add(sessionTTL - time.Minute)}
	for i := 0; i < sessionMaxCount-3; i++ {
		tok := randomID(32)
		s.auth.sessions[sha256.Sum256([]byte(tok))] = session{Expires: now.Add(24*time.Hour + time.Duration(i)*time.Minute)}
	}
	if len(s.auth.sessions) != sessionMaxCount {
		s.auth.mu.Unlock()
		t.Fatalf("expected %d sessions, got %d", sessionMaxCount, len(s.auth.sessions))
	}
	if err := s.auth.saveSessions(); err != nil {
		s.auth.mu.Unlock()
		t.Fatal(err)
	}
	s.auth.mu.Unlock()

	newestToken := loginToken(t, s)
	s.auth.mu.Lock()
	count := len(s.auth.sessions)
	s.auth.mu.Unlock()
	if count != sessionMaxCount {
		t.Fatalf("session count after eviction=%d, want %d", count, sessionMaxCount)
	}
	if w := request(h, "GET", "/api/v1/tracks", "", stalestToken); w.Code != 401 {
		t.Fatalf("stalest session was not evicted: %d", w.Code)
	}
	if w := request(h, "GET", "/api/v1/tracks", "", activeToken); w.Code != 200 {
		t.Fatalf("active session was evicted: %d", w.Code)
	}
	if w := request(h, "GET", "/api/v1/tracks", "", newestToken); w.Code != 200 {
		t.Fatalf("newest session rejected: %d", w.Code)
	}

	// Failure while evicting at capacity must restore the candidate evicted session.
	if err := os.Remove(s.auth.sessionPath()); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(s.auth.sessionPath(), 0700); err != nil {
		t.Fatal(err)
	}
	if w := request(h, "POST", "/api/v1/auth/login", `{"username":"admin","password":"a-test-password-123"}`, ""); w.Code != 500 {
		t.Fatalf("failed login with eviction returned %d, want 500", w.Code)
	}
	s.auth.mu.Lock()
	countAfterFail := len(s.auth.sessions)
	s.auth.mu.Unlock()
	if countAfterFail != sessionMaxCount {
		t.Fatalf("rollback changed session count to %d", countAfterFail)
	}
	if w := request(h, "GET", "/api/v1/tracks", "", secondStalestToken); w.Code != 200 {
		t.Fatalf("failed login lost candidate evicted session: %d", w.Code)
	}
}
