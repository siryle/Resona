package resona

import (
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	sessionTTL               = 365 * 24 * time.Hour
	sessionRenewInterval     = 24 * time.Hour
	sessionRefreshMinPersist = time.Minute
	sessionMaxCount          = 128
)

type session struct {
	Expires time.Time
}

type attempt struct {
	Count int
	Since time.Time
}

type Auth struct {
	mu        sync.Mutex
	user      string
	hash      []byte
	salt      []byte
	sessions  map[[32]byte]session
	attempts  map[string]attempt
	secure    bool
	path      string
	setupCode string
	trusted   []netip.Prefix
	clock     func() time.Time
}

func (a *Auth) now() time.Time {
	if a.clock != nil {
		return a.clock()
	}
	return time.Now()
}

func NewAuth(c Config) (*Auth, error) {
	a := &Auth{user: c.Username, secure: c.CookieSecure, path: filepath.Join(c.DataDir, "admin.json"),
		sessions: map[[32]byte]session{}, attempts: map[string]attempt{}, trusted: c.TrustedProxies}
	data, err := os.ReadFile(a.path)
	if errors.Is(err, os.ErrNotExist) {
		a.setupCode = randomID(16)
		return a, nil
	}
	if err != nil {
		return nil, err
	}
	var saved credentials
	if err := json.Unmarshal(data, &saved); err != nil {
		return nil, fmt.Errorf("invalid administrator credentials (refusing to reset): %w", err)
	}
	if len(saved.Salt) != 32 || len(saved.Hash) != 32 || saved.Username == "" {
		return nil, errors.New("invalid administrator credentials (refusing to reset)")
	}
	a.user, a.salt, a.hash = saved.Username, saved.Salt, saved.Hash
	data, err = os.ReadFile(a.sessionPath())
	if errors.Is(err, os.ErrNotExist) {
		return a, nil
	}
	if err != nil {
		return nil, err
	}
	var sessions savedSessions
	if err := json.Unmarshal(data, &sessions); err != nil {
		return nil, fmt.Errorf("invalid saved sessions: %w", err)
	}
	// A restored session file must belong to the current administrator credentials.
	if sessions.Credentials != a.credentialID() {
		return a, nil
	}
	now := a.now()
	for digest, s := range sessions.Sessions {
		key, err := hex.DecodeString(digest)
		if err != nil || len(key) != sha256.Size {
			return nil, errors.New("invalid saved session digest")
		}
		if now.Before(s.Expires) {
			a.sessions[[32]byte(key)] = s
		}
	}
	if len(a.sessions) > sessionMaxCount {
		return nil, errors.New("too many saved sessions")
	}
	return a, nil
}

type savedSessions struct {
	Credentials string             `json:"credentials"`
	Sessions    map[string]session `json:"sessions"`
}

func (a *Auth) sessionPath() string { return filepath.Join(filepath.Dir(a.path), "sessions.json") }

func (a *Auth) credentialID() string {
	digest := sha256.Sum256(append(append([]byte(a.user), a.salt...), a.hash...))
	return hex.EncodeToString(digest[:])
}

// Called with the auth mutex held; only token digests ever reach disk.
func (a *Auth) saveSessions() error {
	saved := savedSessions{Credentials: a.credentialID(), Sessions: map[string]session{}}
	now := a.now()
	for key, s := range a.sessions {
		if now.Before(s.Expires) {
			saved.Sessions[hex.EncodeToString(key[:])] = s
		}
	}
	f, err := os.CreateTemp(filepath.Dir(a.path), ".sessions-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	err = json.NewEncoder(f).Encode(saved)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), a.sessionPath())
}

type credentials struct {
	Username string `json:"username"`
	Salt     []byte `json:"salt"`
	Hash     []byte `json:"hash"`
}

var errAlreadyConfigured = errors.New("administrator password is already configured")
var errSetupRequired = errors.New("请先在服务端网页设置管理员密码")
var errSetupCode = errors.New("初始化码不正确，请查看服务端启动日志")
var errPasswordPolicy = errors.New("密码至少需要 8 个字符，且不能超过 1024 字节")

func (a *Auth) initialized() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.hash) != 0
}

func (a *Auth) setup(r *http.Request, password, code string) error {
	if utf8.RuneCountInString(password) < 8 || len(password) > 1024 {
		return errPasswordPolicy
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if len(a.hash) != 0 {
		return errAlreadyConfigured
	}
	if r != nil {
		if err := a.consumeAttempt(a.clientAddress(r), a.now()); err != nil {
			return err
		}
	}
	if subtle.ConstantTimeCompare([]byte(code), []byte(a.setupCode)) != 1 {
		return errSetupCode
	}
	if r != nil {
		delete(a.attempts, a.clientAddress(r))
	}
	salt := secureRandom(32)
	hash, err := pbkdf2.Key(sha256.New, password, salt, 600000, 32)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(a.path), ".admin-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	err = json.NewEncoder(f).Encode(credentials{Username: a.user, Salt: salt, Hash: hash})
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	// Atomically create once; concurrent setup requests can never replace credentials.
	if err := os.Link(f.Name(), a.path); err != nil {
		if errors.Is(err, os.ErrExist) {
			return errAlreadyConfigured
		}
		return err
	}
	a.salt, a.hash = salt, hash
	return nil
}

func randomID(bytes int) string {
	return hex.EncodeToString(secureRandom(bytes))
}

func secureRandom(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

var errThrottled = errors.New("too many login attempts")
var errCredentials = errors.New("invalid username or password")

func (a *Auth) login(r *http.Request, user, password string) (string, error) {
	host := a.clientAddress(r)
	now := a.now()
	a.mu.Lock()
	if len(a.hash) == 0 {
		a.mu.Unlock()
		return "", errSetupRequired
	}
	salt, expected, username := append([]byte{}, a.salt...), append([]byte{}, a.hash...), a.user
	if err := a.consumeAttempt(host, now); err != nil {
		a.mu.Unlock()
		return "", err
	}
	a.mu.Unlock()

	hash, err := pbkdf2.Key(sha256.New, password, salt, 600000, 32)
	if err != nil || subtle.ConstantTimeCompare(hash, expected) != 1 ||
		subtle.ConstantTimeCompare([]byte(user), []byte(username)) != 1 {
		return "", errCredentials
	}
	token := randomID(32)
	a.mu.Lock()
	defer a.mu.Unlock()
	for key, s := range a.sessions {
		if !now.Before(s.Expires) {
			delete(a.sessions, key)
		}
	}
	var evictedKey [32]byte
	var evictedSession session
	var evicted bool
	if len(a.sessions) >= sessionMaxCount {
		first := true
		for k, s := range a.sessions {
			if first || s.Expires.Before(evictedSession.Expires) {
				evictedKey, evictedSession, first = k, s, false
			}
		}
		delete(a.sessions, evictedKey)
		evicted = true
	}
	delete(a.attempts, host)
	key := sha256.Sum256([]byte(token))
	a.sessions[key] = session{Expires: now.Add(sessionTTL)}
	if err := a.saveSessions(); err != nil {
		delete(a.sessions, key)
		if evicted {
			a.sessions[evictedKey] = evictedSession
		}
		return "", err
	}
	return token, nil
}

func (a *Auth) clientAddress(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	peer = peer.Unmap()
	if !a.isTrusted(peer) {
		return throttleAddress(peer)
	}
	forwarded := strings.Split(strings.Join(r.Header.Values("X-Forwarded-For"), ","), ",")
	for i := len(forwarded) - 1; i >= 0; i-- {
		address, err := netip.ParseAddr(strings.TrimSpace(forwarded[i]))
		if err != nil {
			break
		}
		if !a.isTrusted(peer) {
			break
		}
		peer = address.Unmap()
	}
	return throttleAddress(peer)
}

// IPv6 clients share a /64. Counting the full address lets one network rotate hosts past the limit.
func throttleAddress(addr netip.Addr) string {
	addr = addr.Unmap()
	if !addr.Is4() {
		prefix, err := addr.Prefix(64)
		if err == nil {
			return prefix.Masked().Addr().String()
		}
	}
	return addr.String()
}

// mu must be held.
func (a *Auth) consumeAttempt(host string, now time.Time) error {
	for key, v := range a.attempts {
		if now.Sub(v.Since) >= 15*time.Minute {
			delete(a.attempts, key)
		}
	}
	at := a.attempts[host]
	if at.Count >= 8 {
		return errThrottled
	}
	if len(a.attempts) >= 4096 && at.Count == 0 {
		var oldestKey string
		var oldest time.Time
		first := true
		for key, v := range a.attempts {
			if first || v.Since.Before(oldest) {
				oldestKey, oldest, first = key, v.Since, false
			}
		}
		delete(a.attempts, oldestKey)
	}
	if at.Count == 0 {
		at.Since = now
	}
	at.Count++
	a.attempts[host] = at
	return nil
}

func (a *Auth) isTrusted(address netip.Addr) bool {
	for _, prefix := range a.trusted {
		if prefix.Contains(address) {
			return true
		}
	}
	return false
}

func requestToken(r *http.Request) (string, bool) {
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		return strings.TrimPrefix(h, "Bearer "), false
	}
	if c, err := r.Cookie("resona_session"); err == nil {
		return c.Value, true
	}
	return "", false
}

func (a *Auth) valid(r *http.Request) bool {
	token, _ := requestToken(r)
	if len(token) != 64 {
		return false
	}
	key := sha256.Sum256([]byte(token))
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	s, ok := a.sessions[key]
	if ok && !now.Before(s.Expires) {
		delete(a.sessions, key)
		return false
	}
	return ok
}

func (a *Auth) authenticate(w http.ResponseWriter, r *http.Request) (bool, error) {
	token, viaCookie := requestToken(r)
	if len(token) != 64 {
		return false, nil
	}
	key := sha256.Sum256([]byte(token))
	now := a.now()
	var renewed bool
	var saveErr error

	a.mu.Lock()
	s, ok := a.sessions[key]
	if ok && !now.Before(s.Expires) {
		delete(a.sessions, key)
		ok = false
	}
	if ok && !s.Expires.After(now.Add(sessionTTL-sessionRenewInterval)) {
		previous := s
		s.Expires = now.Add(sessionTTL)
		a.sessions[key] = s
		if err := a.saveSessions(); err != nil {
			a.sessions[key] = previous
			saveErr = err
		} else {
			renewed = true
		}
	}
	a.mu.Unlock()

	if ok && viaCookie && renewed {
		a.cookie(w, r, token)
	}
	return ok, saveErr
}

func (a *Auth) refresh(w http.ResponseWriter, r *http.Request) (time.Time, bool, error) {
	token, viaCookie := requestToken(r)
	if len(token) != 64 {
		return time.Time{}, false, nil
	}
	key := sha256.Sum256([]byte(token))
	now := a.now()

	a.mu.Lock()
	s, ok := a.sessions[key]
	if ok && !now.Before(s.Expires) {
		delete(a.sessions, key)
		ok = false
	}
	if !ok {
		a.mu.Unlock()
		return time.Time{}, false, nil
	}
	nextExpires := now.Add(sessionTTL)
	if nextExpires.Sub(s.Expires) >= sessionRefreshMinPersist {
		previous := s
		s.Expires = nextExpires
		a.sessions[key] = s
		if err := a.saveSessions(); err != nil {
			a.sessions[key] = previous
			a.mu.Unlock()
			return time.Time{}, true, err
		}
	}
	expires := s.Expires
	a.mu.Unlock()

	if viaCookie {
		a.cookie(w, r, token)
	}
	return expires, true, nil
}

func (a *Auth) tokenExpiry(token string) (time.Time, bool) {
	if len(token) != 64 {
		return time.Time{}, false
	}
	key := sha256.Sum256([]byte(token))
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	s, ok := a.sessions[key]
	if !ok || !now.Before(s.Expires) {
		return time.Time{}, false
	}
	return s.Expires, true
}

func (a *Auth) sessionExpiry(r *http.Request) (time.Time, bool) {
	token, _ := requestToken(r)
	return a.tokenExpiry(token)
}

func (a *Auth) cookie(w http.ResponseWriter, r *http.Request, token string) {
	age := int(sessionTTL / time.Second)
	if token == "" {
		age = -1
	}
	http.SetCookie(w, &http.Cookie{Name: "resona_session", Value: token, Path: "/", HttpOnly: true,
		SameSite: http.SameSiteStrictMode, Secure: a.secure || r.TLS != nil, MaxAge: age})
}

func (a *Auth) logout(w http.ResponseWriter, r *http.Request) error {
	token, _ := requestToken(r)
	a.mu.Lock()
	defer a.mu.Unlock()
	key := sha256.Sum256([]byte(token))
	s, ok := a.sessions[key]
	delete(a.sessions, key)
	if err := a.saveSessions(); err != nil {
		if ok {
			a.sessions[key] = s
		}
		return err
	}
	a.cookie(w, r, "")
	return nil
}
