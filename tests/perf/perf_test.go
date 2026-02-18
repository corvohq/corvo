//go:build perf

package perf_test

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/corvohq/corvo/sdk/go/client"
	"github.com/corvohq/corvo/sdk/go/worker"
)

func TestPerfE2EEnqueueHTTP(t *testing.T) {
	baseURL := startRealServer(t, false)
	c := client.New(baseURL)

	total := envInt("CORVO_PERF_E2E_ENQ_TOTAL", 4000)
	concurrency := envInt("CORVO_PERF_E2E_ENQ_CONCURRENCY", 10)
	minOps := envFloat("CORVO_PERF_E2E_ENQ_MIN_OPS", 100.0)

	start := time.Now()
	var wg sync.WaitGroup
	var failures atomic.Int64
	per := total / concurrency
	rem := total % concurrency
	for i := 0; i < concurrency; i++ {
		n := per
		if i < rem {
			n++
		}
		wg.Add(1)
		go func(count int) {
			defer wg.Done()
			for j := 0; j < count; j++ {
				if _, err := c.Enqueue("perf.e2e.http", map[string]any{}); err != nil {
					failures.Add(1)
				}
			}
		}(n)
	}
	wg.Wait()

	if n := failures.Load(); n > 0 {
		t.Fatalf("enqueue failures=%d", n)
	}
	elapsed := time.Since(start)
	ops := float64(total) / elapsed.Seconds()
	t.Logf("e2e enqueue http: total=%d concurrency=%d elapsed=%s ops/sec=%.1f", total, concurrency, elapsed.Round(time.Millisecond), ops)
	if ops < minOps {
		t.Fatalf("e2e enqueue http perf regression: ops/sec %.1f below threshold %.1f", ops, minOps)
	}
}

func TestPerfE2ELifecycleRPC(t *testing.T) {
	baseURL := startRealServer(t, false)
	c := client.New(baseURL)
	wc := worker.New(baseURL)

	total := envInt("CORVO_PERF_E2E_LC_TOTAL", 3000)
	concurrency := envInt("CORVO_PERF_E2E_LC_CONCURRENCY", 10)
	fetchBatch := envInt("CORVO_PERF_E2E_LC_FETCH_BATCH", 8)
	ackBatch := envInt("CORVO_PERF_E2E_LC_ACK_BATCH", 64)
	minOps := envFloat("CORVO_PERF_E2E_LC_MIN_OPS", 80.0)

	for i := 0; i < total; i++ {
		if _, err := c.Enqueue("perf.e2e.rpc", map[string]any{}); err != nil {
			t.Fatalf("seed enqueue failed at %d: %v", i, err)
		}
	}

	start := time.Now()
	var done atomic.Int64
	var failures atomic.Int64
	var wg sync.WaitGroup

	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(workerID string) {
			defer wg.Done()
			ctx := context.Background()
			pending := make([]worker.AckBatchItem, 0, ackBatch*2)
			for {
				if int(done.Load()) >= total {
					return
				}
				if len(pending) > 0 {
					n := ackBatch
					if n > len(pending) {
						n = len(pending)
					}
					acked, err := wc.AckBatch(ctx, pending[:n])
					if err != nil {
						failures.Add(1)
						time.Sleep(1 * time.Millisecond)
						continue
					}
					done.Add(int64(acked))
					pending = pending[n:]
				}

				if int(done.Load()) >= total {
					return
				}
				remaining := total - int(done.Load()) - len(pending)
				if remaining <= 0 {
					continue
				}
				n := fetchBatch
				if n > remaining {
					n = remaining
				}
				jobs, err := wc.FetchBatch(ctx, worker.FetchRequest{
					Queues:        []string{"perf.e2e.rpc"},
					WorkerID:      workerID,
					Hostname:      "perf-host",
					LeaseDuration: 5,
				}, n)
				if err != nil {
					failures.Add(1)
					time.Sleep(1 * time.Millisecond)
					continue
				}
				if len(jobs) == 0 {
					time.Sleep(1 * time.Millisecond)
					continue
				}
				for _, j := range jobs {
					pending = append(pending, worker.AckBatchItem{
						JobID:  j.JobID,
						Result: json.RawMessage(`{}`),
					})
				}
			}
		}("perf-worker-" + strconv.Itoa(i))
	}
	wg.Wait()

	if got := int(done.Load()); got < total {
		t.Fatalf("lifecycle incomplete: got=%d want=%d failures=%d", got, total, failures.Load())
	}
	if n := failures.Load(); n > 0 {
		t.Logf("e2e lifecycle rpc had recoverable failures=%d", n)
	}
	elapsed := time.Since(start)
	ops := float64(total) / elapsed.Seconds()
	t.Logf("e2e lifecycle rpc: total=%d concurrency=%d elapsed=%s ops/sec=%.1f", total, concurrency, elapsed.Round(time.Millisecond), ops)
	if ops < minOps {
		t.Fatalf("e2e lifecycle rpc perf regression: ops/sec %.1f below threshold %.1f", ops, minOps)
	}
}

func TestPerfE2ELifecycleStream(t *testing.T) {
	baseURL := startRealServer(t, false)
	c := client.New(baseURL)
	wc := worker.New(baseURL)

	total := envInt("CORVO_PERF_E2E_STREAM_TOTAL", 3000)
	concurrency := envInt("CORVO_PERF_E2E_STREAM_CONCURRENCY", 10)
	fetchBatch := envInt("CORVO_PERF_E2E_STREAM_FETCH_BATCH", 16)
	ackBatch := envInt("CORVO_PERF_E2E_STREAM_ACK_BATCH", 64)
	minOps := envFloat("CORVO_PERF_E2E_STREAM_MIN_OPS", 200.0)

	// Seed jobs using batch enqueue for speed.
	const seedBatch = 100
	for i := 0; i < total; i += seedBatch {
		n := seedBatch
		if n > total-i {
			n = total - i
		}
		jobs := make([]client.BatchJob, n)
		for j := range jobs {
			jobs[j] = client.BatchJob{Queue: "perf.e2e.stream", Payload: map[string]any{}}
		}
		if _, err := c.EnqueueBatch(client.BatchRequest{Jobs: jobs}); err != nil {
			t.Fatalf("seed batch enqueue failed at %d: %v", i, err)
		}
	}

	start := time.Now()
	var done atomic.Int64
	var failures atomic.Int64
	var wg sync.WaitGroup

	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(workerID string) {
			defer wg.Done()
			ctx := context.Background()
			stream := wc.OpenLifecycleStream(ctx)
			defer stream.Close()
			var reqID uint64 = 1

			pending := make([]worker.AckBatchItem, 0, ackBatch*2)
			for {
				if int(done.Load()) >= total && len(pending) == 0 {
					return
				}

				// Build acks from pending.
				ackN := ackBatch
				if ackN > len(pending) {
					ackN = len(pending)
				}
				acks := pending[:ackN]

				// Determine fetch count.
				fetchN := 0
				remaining := total - int(done.Load()) - len(pending)
				if remaining > 0 {
					fetchN = fetchBatch
					if fetchN > remaining {
						fetchN = remaining
					}
				}

				resp, err := stream.Exchange(worker.LifecycleRequest{
					RequestID:    reqID,
					Queues:       []string{"perf.e2e.stream"},
					WorkerID:     workerID,
					Hostname:     "perf-host",
					LeaseSeconds: 10,
					FetchCount:   fetchN,
					Acks:         acks,
				})
				reqID++

				if err != nil {
					failures.Add(1)
					// Reopen stream on error.
					stream.Close()
					stream = wc.OpenLifecycleStream(ctx)
					time.Sleep(2 * time.Millisecond)
					continue
				}
				if resp.Error != "" {
					failures.Add(1)
					time.Sleep(1 * time.Millisecond)
					continue
				}

				// Account for acked jobs.
				acked := resp.Acked
				if acked > len(pending) {
					acked = len(pending)
				}
				done.Add(int64(acked))
				pending = pending[acked:]

				// Append newly fetched jobs.
				for _, j := range resp.Jobs {
					pending = append(pending, worker.AckBatchItem{
						JobID:  j.JobID,
						Result: json.RawMessage(`{}`),
					})
				}

				if len(resp.Jobs) == 0 && fetchN > 0 && len(pending) == 0 {
					time.Sleep(1 * time.Millisecond)
				}
			}
		}("perf-stream-worker-" + strconv.Itoa(i))
	}
	wg.Wait()

	if got := int(done.Load()); got < total {
		t.Fatalf("stream lifecycle incomplete: got=%d want=%d failures=%d", got, total, failures.Load())
	}
	if n := failures.Load(); n > 0 {
		t.Logf("e2e lifecycle stream had recoverable failures=%d", n)
	}
	elapsed := time.Since(start)
	ops := float64(total) / elapsed.Seconds()
	t.Logf("e2e lifecycle stream: total=%d concurrency=%d elapsed=%s ops/sec=%.1f", total, concurrency, elapsed.Round(time.Millisecond), ops)
	if ops < minOps {
		t.Fatalf("e2e lifecycle stream perf regression: ops/sec %.1f below threshold %.1f", ops, minOps)
	}
}

// startRealServer starts the real `corvo server` command path.
// durable=false means default fast profile; durable=true enables raft fsync mode.
func startRealServer(t *testing.T, durable bool) string {
	t.Helper()
	root := repoRoot(t)
	httpAddr := freeAddr(t)
	raftAddr := freeAddr(t)
	dataDir := t.TempDir()

	args := []string{
		"run", "./cmd/corvo", "server",
		"--bind", httpAddr,
		"--data-dir", dataDir,
		"--raft-bind", raftAddr,
		"--raft-advertise", raftAddr,
		"--rate-limit-enabled=false",
	}
	if durable {
		args = append(args, "--durable")
	}

	cmd := exec.Command("go", args...)
	cmd.Dir = root
	outPath := filepath.Join(dataDir, "server.log")
	logFile, err := os.Create(outPath)
	if err != nil {
		t.Fatalf("create server log: %v", err)
	}
	cmd.Stdout = logFile
	cmd.Stderr = logFile

	if err := cmd.Start(); err != nil {
		t.Fatalf("start corvo server: %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
		_ = logFile.Close()
	})

	baseURL := "http://" + httpAddr
	waitForHealth(t, baseURL, 20*time.Second, outPath)
	return baseURL
}

func waitForHealth(t *testing.T, baseURL string, timeout time.Duration, logPath string) {
	t.Helper()
	httpC := &http.Client{Timeout: 2 * time.Second}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := httpC.Get(baseURL + "/healthz")
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	logBytes, _ := os.ReadFile(logPath)
	t.Fatalf("server did not become healthy within %s; log:\n%s", timeout, strings.TrimSpace(string(logBytes)))
}

func repoRoot(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	cur := wd
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(cur, "go.mod")); err == nil {
			return cur
		}
		next := filepath.Dir(cur)
		if next == cur {
			break
		}
		cur = next
	}
	t.Fatalf("could not locate repo root from %s", wd)
	return ""
}

func freeAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen free addr: %v", err)
	}
	defer ln.Close()
	return ln.Addr().String()
}

func envInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}

func envFloat(key string, fallback float64) float64 {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.ParseFloat(v, 64)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}

func TestPerfHarnessUsesRealServerPath(t *testing.T) {
	if testing.Short() {
		t.Skip("skip in -short")
	}
	root := repoRoot(t)
	if _, err := os.Stat(filepath.Join(root, "cmd", "corvo", "main.go")); err != nil {
		t.Fatalf("expected cmd/corvo/main.go in repo root: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "cmd", "corvo", "cmd_bench.go")); err != nil {
		t.Fatalf("expected cmd/corvo/cmd_bench.go in repo root: %v", err)
	}
	t.Logf("perf harness repo root: %s", root)
}
