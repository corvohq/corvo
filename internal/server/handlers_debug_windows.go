//go:build windows

package server

import (
	"net/http"
	"runtime"
)

type runtimeStats struct {
	Goroutines   int   `json:"goroutines"`
	GoMaxProcs   int   `json:"gomaxprocs"`
	HeapInuse    int64 `json:"heap_inuse_bytes"`
	StackInuse   int64 `json:"stack_inuse_bytes"`
	GCPauseP99Ns int64 `json:"gc_pause_p99_ns"`
	CPUUserNs    int64 `json:"cpu_user_ns"`
	CPUSysNs     int64 `json:"cpu_sys_ns"`
}

func (s *Server) handleDebugRuntime(w http.ResponseWriter, r *http.Request) {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	writeJSON(w, http.StatusOK, runtimeStats{
		Goroutines: runtime.NumGoroutine(),
		GoMaxProcs: runtime.GOMAXPROCS(0),
		HeapInuse:  int64(m.HeapInuse),
		StackInuse: int64(m.StackInuse),
	})
}
