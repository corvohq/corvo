//go:build !windows

package server

import (
	"net/http"
	"runtime"
	"syscall"
)

type runtimeStats struct {
	Goroutines    int   `json:"goroutines"`
	GoMaxProcs    int   `json:"gomaxprocs"`
	HeapInuse     int64 `json:"heap_inuse_bytes"`
	StackInuse    int64 `json:"stack_inuse_bytes"`
	GCPauseP99Ns int64 `json:"gc_pause_p99_ns"`
	CPUUserNs     int64 `json:"cpu_user_ns"`
	CPUSysNs      int64 `json:"cpu_sys_ns"`
}

func (s *Server) handleDebugRuntime(w http.ResponseWriter, r *http.Request) {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	// GC pause p99: PauseNs is a circular buffer of recent GC pauses.
	// Use the 99th percentile of the last NumGC pauses (up to 256).
	var gcP99 uint64
	if m.NumGC > 0 {
		count := int(m.NumGC)
		if count > 256 {
			count = 256
		}
		pauses := make([]uint64, count)
		for i := 0; i < count; i++ {
			idx := (int(m.NumGC) - count + i) % 256
			pauses[i] = m.PauseNs[idx]
		}
		// Simple sort for p99.
		for i := 1; i < len(pauses); i++ {
			for j := i; j > 0 && pauses[j] < pauses[j-1]; j-- {
				pauses[j], pauses[j-1] = pauses[j-1], pauses[j]
			}
		}
		p99idx := len(pauses) * 99 / 100
		if p99idx >= len(pauses) {
			p99idx = len(pauses) - 1
		}
		gcP99 = pauses[p99idx]
	}

	// CPU times via getrusage.
	var rusage syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &rusage)
	userNs := int64(rusage.Utime.Sec)*1e9 + int64(rusage.Utime.Usec)*1e3
	sysNs := int64(rusage.Stime.Sec)*1e9 + int64(rusage.Stime.Usec)*1e3

	writeJSON(w, http.StatusOK, runtimeStats{
		Goroutines:    runtime.NumGoroutine(),
		GoMaxProcs:    runtime.GOMAXPROCS(0),
		HeapInuse:     int64(m.HeapInuse),
		StackInuse:    int64(m.StackInuse),
		GCPauseP99Ns: int64(gcP99),
		CPUUserNs:     userNs,
		CPUSysNs:      sysNs,
	})
}
