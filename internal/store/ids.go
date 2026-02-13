package store

import (
	"encoding/hex"
	"sync/atomic"
	"time"
)

var (
	idSeq uint64
)

// newSortableID generates a lexicographically sortable 26-char ID suffix.
// Layout (hex): 16 chars timestamp ns + 10 chars sequence.
func newSortableID() string {
	ns := uint64(time.Now().UnixNano())
	seq := atomic.AddUint64(&idSeq, 1)
	var raw [13]byte
	raw[0] = byte(ns >> 56)
	raw[1] = byte(ns >> 48)
	raw[2] = byte(ns >> 40)
	raw[3] = byte(ns >> 32)
	raw[4] = byte(ns >> 24)
	raw[5] = byte(ns >> 16)
	raw[6] = byte(ns >> 8)
	raw[7] = byte(ns)
	// Keep lower 40 bits for a fixed 10-hex-char suffix.
	raw[8] = byte(seq >> 32)
	raw[9] = byte(seq >> 24)
	raw[10] = byte(seq >> 16)
	raw[11] = byte(seq >> 8)
	raw[12] = byte(seq)
	dst := make([]byte, 26)
	hex.Encode(dst, raw[:])
	return string(dst)
}

// NewJobID generates a new job ID with the "job_" prefix.
func NewJobID() string {
	return "job_" + newSortableID()
}

// NewBatchID generates a new batch ID with the "batch_" prefix.
func NewBatchID() string {
	return "batch_" + newSortableID()
}

// NewScheduleID generates a new schedule ID with the "sched_" prefix.
func NewScheduleID() string {
	return "sched_" + newSortableID()
}
