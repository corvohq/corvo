package server

import (
	"crypto/sha256"
	"encoding/hex"
	"net"
	"net/http"
	"strings"
	"sync"
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
	mu   sync.Mutex
	cfg  RateLimitConfig
	bkt  map[string]*clientBuckets
	ttl  time.Duration
	stop chan struct{}
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
	go rl.cleanupLoop()
	return rl
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

func (r *rateLimiter) close() {
	select {
	case <-r.stop:
	default:
		close(r.stop)
	}
}

func (r *rateLimiter) allow(key string, isWrite bool, now time.Time) bool {
	if !r.cfg.Enabled {
		return true
	}
	key = strings.TrimSpace(key)
	if key == "" {
		key = "anonymous"
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	c := r.bkt[key]
	if c == nil {
		c = &clientBuckets{
			read: tokenBucket{tokens: r.cfg.ReadBurst, last: now},
			wr:   tokenBucket{tokens: r.cfg.WriteBurst, last: now},
			last: now,
		}
		r.bkt[key] = c
	}
	c.last = now
	if isWrite {
		return takeToken(&c.wr, r.cfg.WriteRPS, r.cfg.WriteBurst, now)
	}
	return takeToken(&c.read, r.cfg.ReadRPS, r.cfg.ReadBurst, now)
}

func takeToken(b *tokenBucket, rps, burst float64, now time.Time) bool {
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
	if b.tokens < 1 {
		return false
	}
	b.tokens -= 1
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
	if strings.HasPrefix(path, "/api/v1/") || strings.HasPrefix(path, "/jobbie.v1.WorkerService/") {
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
