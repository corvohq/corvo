package server

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var requestDurationBuckets = []float64{
	0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10,
}

type requestMetricKey struct {
	Method string
	Route  string
}

type requestMetricValue struct {
	Total      uint64
	Errors     uint64
	SumSeconds float64
	Buckets    []uint64
}

type requestMetricCounter struct {
	total      atomic.Uint64
	errors     atomic.Uint64
	sumNanos   atomic.Uint64
	buckets    []atomic.Uint64
	inFlight   atomic.Int64
	throttled  atomic.Uint64
	lastUpdate atomic.Int64
}

func newRequestMetricCounter() *requestMetricCounter {
	c := &requestMetricCounter{
		buckets: make([]atomic.Uint64, len(requestDurationBuckets)),
	}
	c.lastUpdate.Store(time.Now().UnixNano())
	return c
}

type requestMetrics struct {
	mu    sync.RWMutex
	byKey map[requestMetricKey]*requestMetricCounter
}

func newRequestMetrics() *requestMetrics {
	return &requestMetrics{byKey: map[requestMetricKey]*requestMetricCounter{}}
}

func (m *requestMetrics) begin(method, route string) *requestMetricCounter {
	key := requestMetricKey{Method: strings.ToUpper(strings.TrimSpace(method)), Route: normalizeMetricRoute(route)}
	m.mu.RLock()
	c := m.byKey[key]
	m.mu.RUnlock()
	if c == nil {
		m.mu.Lock()
		c = m.byKey[key]
		if c == nil {
			c = newRequestMetricCounter()
			m.byKey[key] = c
		}
		m.mu.Unlock()
	}
	c.inFlight.Add(1)
	c.lastUpdate.Store(time.Now().UnixNano())
	return c
}

func (m *requestMetrics) finish(c *requestMetricCounter, status int, dur time.Duration) {
	if c == nil {
		return
	}
	c.total.Add(1)
	if status >= 400 {
		c.errors.Add(1)
	}
	if dur > 0 {
		c.sumNanos.Add(uint64(dur.Nanoseconds()))
		d := dur.Seconds()
		for i, b := range requestDurationBuckets {
			if d <= b {
				c.buckets[i].Add(1)
			}
		}
	}
	c.inFlight.Add(-1)
	c.lastUpdate.Store(time.Now().UnixNano())
}

func (m *requestMetrics) incThrottled(method, route string) {
	c := m.begin(method, route)
	c.throttled.Add(1)
	c.inFlight.Add(-1)
}

func (m *requestMetrics) snapshot() map[requestMetricKey]requestMetricValue {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make(map[requestMetricKey]requestMetricValue, len(m.byKey))
	for k, c := range m.byKey {
		v := requestMetricValue{
			Total:      c.total.Load(),
			Errors:     c.errors.Load(),
			SumSeconds: float64(c.sumNanos.Load()) / float64(time.Second),
			Buckets:    make([]uint64, len(c.buckets)),
		}
		for i := range c.buckets {
			v.Buckets[i] = c.buckets[i].Load()
		}
		out[k] = v
	}
	return out
}

func normalizeMetricRoute(route string) string {
	route = strings.TrimSpace(route)
	if route == "" {
		return "/unknown"
	}
	if !strings.HasPrefix(route, "/") {
		route = "/" + route
	}
	parts := strings.Split(route, "/")
	for i := 0; i < len(parts); i++ {
		p := strings.TrimSpace(parts[i])
		if p == "" {
			continue
		}
		if strings.HasPrefix(p, "job_") || strings.HasPrefix(p, "bulk_") || strings.HasPrefix(p, "budget_") {
			parts[i] = ":id"
			continue
		}
		if len(p) >= 24 && isHexLike(p) {
			parts[i] = ":id"
		}
	}
	route = strings.Join(parts, "/")
	return route
}

func isHexLike(v string) bool {
	for _, ch := range v {
		if (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F') {
			continue
		}
		return false
	}
	return true
}

func (m *requestMetrics) renderPrometheus() string {
	snap := m.snapshot()
	keys := make([]requestMetricKey, 0, len(snap))
	for k := range snap {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].Route == keys[j].Route {
			return keys[i].Method < keys[j].Method
		}
		return keys[i].Route < keys[j].Route
	})

	var b strings.Builder
	b.WriteString("# HELP jobbie_http_requests_total HTTP requests received.\n")
	b.WriteString("# TYPE jobbie_http_requests_total counter\n")
	b.WriteString("# HELP jobbie_http_request_errors_total HTTP requests resulting in 4xx/5xx.\n")
	b.WriteString("# TYPE jobbie_http_request_errors_total counter\n")
	b.WriteString("# HELP jobbie_http_request_duration_seconds HTTP request duration in seconds.\n")
	b.WriteString("# TYPE jobbie_http_request_duration_seconds histogram\n")
	b.WriteString("# HELP jobbie_http_requests_in_flight Current in-flight HTTP requests.\n")
	b.WriteString("# TYPE jobbie_http_requests_in_flight gauge\n")
	b.WriteString("# HELP jobbie_rate_limit_throttled_total Requests denied by server-side rate limiting.\n")
	b.WriteString("# TYPE jobbie_rate_limit_throttled_total counter\n")
	for _, k := range keys {
		v := snap[k]
		method := promLabelEscape(k.Method)
		route := promLabelEscape(k.Route)
		b.WriteString(fmt.Sprintf("jobbie_http_requests_total{method=\"%s\",route=\"%s\"} %d\n", method, route, v.Total))
		b.WriteString(fmt.Sprintf("jobbie_http_request_errors_total{method=\"%s\",route=\"%s\"} %d\n", method, route, v.Errors))
		var cumulative uint64
		for i, bucket := range requestDurationBuckets {
			cumulative = v.Buckets[i]
			b.WriteString(fmt.Sprintf("jobbie_http_request_duration_seconds_bucket{method=\"%s\",route=\"%s\",le=\"%g\"} %d\n", method, route, bucket, cumulative))
		}
		b.WriteString(fmt.Sprintf("jobbie_http_request_duration_seconds_bucket{method=\"%s\",route=\"%s\",le=\"+Inf\"} %d\n", method, route, v.Total))
		b.WriteString(fmt.Sprintf("jobbie_http_request_duration_seconds_sum{method=\"%s\",route=\"%s\"} %.9f\n", method, route, v.SumSeconds))
		b.WriteString(fmt.Sprintf("jobbie_http_request_duration_seconds_count{method=\"%s\",route=\"%s\"} %d\n", method, route, v.Total))
	}
	m.mu.RLock()
	defer m.mu.RUnlock()
	var inflight int64
	for _, c := range m.byKey {
		inflight += c.inFlight.Load()
	}
	b.WriteString(fmt.Sprintf("jobbie_http_requests_in_flight %d\n", inflight))
	for _, k := range keys {
		c := m.byKey[k]
		if c == nil {
			continue
		}
		th := c.throttled.Load()
		if th == 0 {
			continue
		}
		method := promLabelEscape(k.Method)
		route := promLabelEscape(k.Route)
		b.WriteString(fmt.Sprintf("jobbie_rate_limit_throttled_total{method=\"%s\",route=\"%s\"} %d\n", method, route, th))
	}
	return b.String()
}
