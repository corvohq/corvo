package server

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type RateLimitConfig struct {
	Enabled    bool
	ReadRPS    float64
	ReadBurst  float64
	WriteRPS   float64
	WriteBurst float64
}

type tokenBucket struct {
	tokens float64
	last   time.Time
}

type clientBuckets struct {
	read tokenBucket
	wr   tokenBucket
	last time.Time
}

type rateLimiter struct {
	mu        sync.Mutex
	cfg       RateLimitConfig
	bkt       map[string]*clientBuckets
	ttl       time.Duration
	stop      chan struct{}
	nsConfigs atomic.Pointer[map[string]*RateLimitConfig] // namespace → config
	keyNS     atomic.Pointer[map[string]string]            // rate limit key → namespace
	dbLoader  func() (*sql.DB, bool)
}

func newRateLimiter(cfg RateLimitConfig) *rateLimiter {
	if cfg.ReadRPS <= 0 {
		cfg.ReadRPS = 2000
	}
	if cfg.ReadBurst <= 0 {
		cfg.ReadBurst = 4000
	}
	if cfg.WriteRPS <= 0 {
		cfg.WriteRPS = 1000
	}
	if cfg.WriteBurst <= 0 {
		cfg.WriteBurst = 2000
	}
	rl := &rateLimiter{
		cfg:  cfg,
		bkt:  map[string]*clientBuckets{},
		ttl:  10 * time.Minute,
		stop: make(chan struct{}),
	}
	// Initialize empty maps so atomic loads never return nil.
	emptyNS := make(map[string]*RateLimitConfig)
	rl.nsConfigs.Store(&emptyNS)
	emptyKey := make(map[string]string)
	rl.keyNS.Store(&emptyKey)

	go rl.cleanupLoop()
	return rl
}

func (r *rateLimiter) setDBLoader(loader func() (*sql.DB, bool)) {
	r.dbLoader = loader
	// Do an initial load and start the refresh loop.
	r.loadNamespaceConfigs()
	go r.refreshLoop()
}

func (r *rateLimiter) cleanupLoop() {
	t := time.NewTicker(1 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-r.stop:
			return
		case <-t.C:
			cutoff := time.Now().Add(-r.ttl)
			r.mu.Lock()
			for k, v := range r.bkt {
				if v.last.Before(cutoff) {
					delete(r.bkt, k)
				}
			}
			r.mu.Unlock()
		}
	}
}

func (r *rateLimiter) refreshLoop() {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-r.stop:
			return
		case <-t.C:
			r.loadNamespaceConfigs()
		}
	}
}

func (r *rateLimiter) loadNamespaceConfigs() {
	if r.dbLoader == nil {
		return
	}
	db, ok := r.dbLoader()
	if !ok || db == nil {
		return
	}

	// Load namespace rate limit overrides.
	nsMap := make(map[string]*RateLimitConfig)
	rows, err := db.Query(`SELECT name, rate_limit_read_rps, rate_limit_read_burst,
		rate_limit_write_rps, rate_limit_write_burst FROM namespaces
		WHERE rate_limit_read_rps IS NOT NULL OR rate_limit_read_burst IS NOT NULL
		   OR rate_limit_write_rps IS NOT NULL OR rate_limit_write_burst IS NOT NULL`)
	if err != nil {
		slog.Debug("rate limiter: failed to load namespace configs", "error", err)
		return
	}
	defer rows.Close()
	for rows.Next() {
		var name string
		var readRPS, readBurst, writeRPS, writeBurst sql.NullFloat64
		if err := rows.Scan(&name, &readRPS, &readBurst, &writeRPS, &writeBurst); err != nil {
			slog.Debug("rate limiter: failed to scan namespace config", "error", err)
			continue
		}
		cfg := &RateLimitConfig{Enabled: true}
		if readRPS.Valid {
			cfg.ReadRPS = readRPS.Float64
		} else {
			cfg.ReadRPS = r.cfg.ReadRPS
		}
		if readBurst.Valid {
			cfg.ReadBurst = readBurst.Float64
		} else {
			cfg.ReadBurst = r.cfg.ReadBurst
		}
		if writeRPS.Valid {
			cfg.WriteRPS = writeRPS.Float64
		} else {
			cfg.WriteRPS = r.cfg.WriteRPS
		}
		if writeBurst.Valid {
			cfg.WriteBurst = writeBurst.Float64
		} else {
			cfg.WriteBurst = r.cfg.WriteBurst
		}
		nsMap[name] = cfg
	}
	if err := rows.Err(); err != nil {
		slog.Debug("rate limiter: namespace config rows error", "error", err)
		return
	}

	// Load key_hash → namespace mappings for all API keys.
	keyMap := make(map[string]string)
	keyRows, err := db.Query("SELECT key_hash, namespace FROM api_keys WHERE enabled = 1")
	if err != nil {
		slog.Debug("rate limiter: failed to load api key mappings", "error", err)
		// Still swap nsConfigs even if key mapping fails.
		r.nsConfigs.Store(&nsMap)
		return
	}
	defer keyRows.Close()
	for keyRows.Next() {
		var keyHash, ns string
		if err := keyRows.Scan(&keyHash, &ns); err != nil {
			continue
		}
		// The rate limit key for API keys is "api:" + first 16 hex chars of sha256.
		// key_hash in the DB is the full hex sha256. We take the first 16 chars
		// to match what hashSensitive produces (first 8 bytes = 16 hex chars).
		if len(keyHash) >= 16 {
			keyMap["api:"+keyHash[:16]] = ns
		}
	}

	// Atomic swap — readers see a consistent snapshot.
	r.nsConfigs.Store(&nsMap)
	r.keyNS.Store(&keyMap)
}

// configForKey returns the effective rate limit config for a given client key.
// Lock-free: 2 atomic pointer loads + 2 map lookups.
func (r *rateLimiter) configForKey(key string) RateLimitConfig {
	kns := r.keyNS.Load()
	if kns != nil {
		if ns, ok := (*kns)[key]; ok {
			nsc := r.nsConfigs.Load()
			if nsc != nil {
				if cfg, ok := (*nsc)[ns]; ok {
					return *cfg
				}
			}
		}
	}
	return r.cfg
}

func (r *rateLimiter) close() {
	select {
	case <-r.stop:
	default:
		close(r.stop)
	}
}

func (r *rateLimiter) allow(key string, isWrite bool, now time.Time) bool {
	return r.allowN(key, isWrite, 1, now)
}

func (r *rateLimiter) allowN(key string, isWrite bool, n int, now time.Time) bool {
	if !r.cfg.Enabled {
		return true
	}
	if n <= 0 {
		n = 1
	}
	key = strings.TrimSpace(key)
	if key == "" {
		key = "anonymous"
	}

	cfg := r.configForKey(key)

	r.mu.Lock()
	defer r.mu.Unlock()
	c := r.bkt[key]
	if c == nil {
		c = &clientBuckets{
			read: tokenBucket{tokens: cfg.ReadBurst, last: now},
			wr:   tokenBucket{tokens: cfg.WriteBurst, last: now},
			last: now,
		}
		r.bkt[key] = c
	}
	c.last = now
	if isWrite {
		return takeTokenN(&c.wr, cfg.WriteRPS, cfg.WriteBurst, now, n)
	}
	return takeTokenN(&c.read, cfg.ReadRPS, cfg.ReadBurst, now, n)
}

func takeToken(b *tokenBucket, rps, burst float64, now time.Time) bool {
	return takeTokenN(b, rps, burst, now, 1)
}

func takeTokenN(b *tokenBucket, rps, burst float64, now time.Time, n int) bool {
	if n <= 0 {
		n = 1
	}
	if b.last.IsZero() {
		b.last = now
	}
	elapsed := now.Sub(b.last).Seconds()
	if elapsed > 0 {
		b.tokens += elapsed * rps
		if b.tokens > burst {
			b.tokens = burst
		}
	}
	b.last = now
	cost := float64(n)
	if b.tokens < cost {
		return false
	}
	b.tokens -= cost
	return true
}

func isWriteMethod(method string) bool {
	switch method {
	case http.MethodGet, http.MethodHead, http.MethodOptions:
		return false
	default:
		return true
	}
}

func isRateLimitedPath(path string) bool {
	if path == "/healthz" || strings.HasPrefix(path, "/ui/") || path == "/ui" {
		return false
	}
	// StreamLifecycle is a long-lived bidi stream; counting it with the
	// same request limiter as short unary endpoints can throttle reconnect
	// storms and amplify client retries. It has dedicated stream controls.
	if path == "/corvo.v1.WorkerService/StreamLifecycle" {
		return false
	}
	if strings.HasPrefix(path, "/api/v1/") || strings.HasPrefix(path, "/corvo.v1.WorkerService/") {
		return true
	}
	return false
}

func rateLimitClientKey(r *http.Request) string {
	if r == nil {
		return "unknown"
	}
	if k := strings.TrimSpace(r.Header.Get("X-API-Key")); k != "" {
		return "api:" + hashSensitive(k)
	}
	if auth := strings.TrimSpace(r.Header.Get("Authorization")); auth != "" {
		return "auth:" + hashSensitive(auth)
	}
	if fwd := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); fwd != "" {
		parts := strings.Split(fwd, ",")
		if len(parts) > 0 {
			ip := strings.TrimSpace(parts[0])
			if ip != "" {
				return "ip:" + ip
			}
		}
	}
	host, _, err := net.SplitHostPort(strings.TrimSpace(r.RemoteAddr))
	if err == nil && host != "" {
		return "ip:" + host
	}
	if strings.TrimSpace(r.RemoteAddr) != "" {
		return "ip:" + strings.TrimSpace(r.RemoteAddr)
	}
	return "unknown"
}

func hashSensitive(v string) string {
	sum := sha256.Sum256([]byte(v))
	return hex.EncodeToString(sum[:8])
}
