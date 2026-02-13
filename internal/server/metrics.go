package server

import (
	"sync"
	"time"
)

const throughputBuckets = 60

// ThroughputBucket holds counts for a single minute.
type ThroughputBucket struct {
	Minute    time.Time `json:"minute"`
	Enqueued  int64     `json:"enqueued"`
	Completed int64     `json:"completed"`
	Failed    int64     `json:"failed"`
}

// ThroughputTracker keeps a 60-minute ring buffer of throughput counters.
type ThroughputTracker struct {
	mu      sync.Mutex
	buckets [throughputBuckets]ThroughputBucket
	head    int // index of the current minute bucket
}

// NewThroughputTracker creates a new tracker.
func NewThroughputTracker() *ThroughputTracker {
	t := &ThroughputTracker{}
	now := time.Now().Truncate(time.Minute)
	for i := range t.buckets {
		t.buckets[i].Minute = now.Add(time.Duration(i-throughputBuckets+1) * time.Minute)
	}
	t.head = throughputBuckets - 1
	return t
}

// advance rolls the ring buffer forward to the current minute if needed.
func (t *ThroughputTracker) advance() {
	now := time.Now().Truncate(time.Minute)
	cur := t.buckets[t.head].Minute

	for cur.Before(now) {
		t.head = (t.head + 1) % throughputBuckets
		cur = cur.Add(time.Minute)
		t.buckets[t.head] = ThroughputBucket{Minute: cur}
	}
}

// Inc increments a counter type for the current minute.
func (t *ThroughputTracker) Inc(typ string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.advance()

	b := &t.buckets[t.head]
	switch typ {
	case "enqueued":
		b.Enqueued++
	case "completed":
		b.Completed++
	case "failed":
		b.Failed++
	}
}

// Snapshot returns all 60 buckets in chronological order.
func (t *ThroughputTracker) Snapshot() []ThroughputBucket {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.advance()

	result := make([]ThroughputBucket, throughputBuckets)
	for i := 0; i < throughputBuckets; i++ {
		idx := (t.head + 1 + i) % throughputBuckets
		result[i] = t.buckets[idx]
	}
	return result
}

// Totals returns cumulative counts across all retained throughput buckets.
func (t *ThroughputTracker) Totals() (enqueued, completed, failed int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.advance()
	for i := 0; i < throughputBuckets; i++ {
		enqueued += t.buckets[i].Enqueued
		completed += t.buckets[i].Completed
		failed += t.buckets[i].Failed
	}
	return enqueued, completed, failed
}
