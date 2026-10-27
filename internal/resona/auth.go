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
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

type session struct {
	Expires time.Time
}

type attempt struct {
	Count int
	Since time.Time
}

type Auth struct {
	mu       sync.Mutex
	user     string
	hash     []byte
	salt     []byte
	sessions map[[32]byte]session
	attempts map[string]attempt
	secure   bool
	path     string
}

func NewAuth(c Config) (*Auth, error) {
	a := &Auth{user: c.Username, secure: c.CookieSecure, path: filepath.Join(c.DataDir, "admin.json"),
		sessions: map[[32]byte]session{}, attempts: map[string]attempt{}}
	data, err := os.ReadFile(a.path)
	if errors.Is(err, os.ErrNotExist) {
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
	for digest, s := range sessions.Sessions {
		key, err := hex.DecodeString(digest)
		if err != nil || len(key) != sha256.Size {
			return nil, errors.New("invalid saved session digest")
		}
		if time.Now().Before(s.Expires) {
			a.sessions[[32]byte(key)] = s
		}
	}
	if len(a.sessions) > 128 {
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
	for key, s := range a.sessions {
		if time.Now().Before(s.Expires) {
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
var errPasswordPolicy = errors.New("密码至少需要 8 个字符，且不能超过 1024 字节")

func (a *Auth) initialized() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.hash) != 0
}

func (a *Auth) setup(password string) error {
	if utf8.RuneCountInString(password) < 8 || len(password) > 1024 {
		return errPasswordPolicy
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if len(a.hash) != 0 {
		return errAlreadyConfigured
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
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if host == "" {
		host = r.RemoteAddr
	}
	now := time.Now()
	a.mu.Lock()
	if len(a.hash) == 0 {
		a.mu.Unlock()
		return "", errSetupRequired
	}
	salt, expected, username := append([]byte{}, a.salt...), append([]byte{}, a.hash...), a.user
	for key, v := range a.attempts {
		if now.Sub(v.Since) >= 15*time.Minute {
			delete(a.attempts, key)
		}
	}
	at := a.attempts[host]
	if at.Count >= 8 || (len(a.attempts) >= 4096 && at.Count == 0) {
		a.mu.Unlock()
		return "", errThrottled
	}
	if at.Count == 0 {
		at.Since = now
	}
	at.Count++
	a.attempts[host] = at
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
	if len(a.sessions) >= 128 {
		return "", errThrottled
	}
	delete(a.attempts, host)
	key := sha256.Sum256([]byte(token))
	a.sessions[key] = session{Expires: now.Add(7 * 24 * time.Hour)}
	if err := a.saveSessions(); err != nil {
		delete(a.sessions, key)
		return "", err
	}
	return token, nil
}

func requestToken(r *http.Request) string {
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		return strings.TrimPrefix(h, "Bearer ")
	}
	if c, err := r.Cookie("resona_session"); err == nil {
		return c.Value
	}
	return ""
}

func (a *Auth) valid(r *http.Request) bool {
	token := requestToken(r)
	if len(token) != 64 {
		return false
	}
	key := sha256.Sum256([]byte(token))
	a.mu.Lock()
	defer a.mu.Unlock()
	s, ok := a.sessions[key]
	if ok && !time.Now().Before(s.Expires) {
		delete(a.sessions, key)
		return false
	}
	return ok
}

func (a *Auth) cookie(w http.ResponseWriter, r *http.Request, token string) {
	age := 7 * 24 * 60 * 60
	if token == "" {
		age = -1
	}
	http.SetCookie(w, &http.Cookie{Name: "resona_session", Value: token, Path: "/", HttpOnly: true,
		SameSite: http.SameSiteStrictMode, Secure: a.secure || r.TLS != nil, MaxAge: age})
}

func (a *Auth) logout(w http.ResponseWriter, r *http.Request) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	key := sha256.Sum256([]byte(requestToken(r)))
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
