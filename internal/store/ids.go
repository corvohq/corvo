package store

import (
	"crypto/rand"
	"sync"
	"time"

	"github.com/oklog/ulid/v2"
)

var (
	entropy     = ulid.Monotonic(rand.Reader, 0)
	entropyLock sync.Mutex
)

// newULID generates a new ULID string.
func newULID() string {
	entropyLock.Lock()
	defer entropyLock.Unlock()
	return ulid.MustNew(ulid.Timestamp(time.Now()), entropy).String()
}

// NewJobID generates a new job ID with the "job_" prefix.
func NewJobID() string {
	return "job_" + newULID()
}

// NewBatchID generates a new batch ID with the "batch_" prefix.
func NewBatchID() string {
	return "batch_" + newULID()
}

// NewScheduleID generates a new schedule ID with the "sched_" prefix.
func NewScheduleID() string {
	return "sched_" + newULID()
}
