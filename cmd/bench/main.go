package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/user/jobbie/pkg/client"
)

type benchResult struct {
	lats    []time.Duration
	elapsed time.Duration
}

func main() {
	server := flag.String("server", "http://localhost:8080", "server URL")
	jobs := flag.Int("jobs", 10000, "total number of jobs to process")
	concurrency := flag.Int("concurrency", 10, "number of concurrent goroutines")
	queue := flag.String("queue", "bench.q", "queue name")
	flag.Parse()

	fmt.Printf("Jobbie Benchmark\n")
	fmt.Printf("  server:      %s\n", *server)
	fmt.Printf("  jobs:        %d\n", *jobs)
	fmt.Printf("  concurrency: %d\n", *concurrency)
	fmt.Printf("  queue:       %s\n\n", *queue)

	c := client.New(*server)
	httpC := &http.Client{Timeout: 30 * time.Second}

	// Health check
	resp, err := httpC.Get(*server + "/healthz")
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot reach server: %v\n", err)
		os.Exit(1)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "server unhealthy: status %d\n", resp.StatusCode)
		os.Exit(1)
	}

	// Clear queue before starting
	clearQueue(httpC, *server, *queue)

	// Benchmark 1: Enqueue throughput
	fmt.Println("=== Enqueue Benchmark ===")
	enqResult := benchEnqueue(c, *jobs, *concurrency, *queue)
	printStats(enqResult)

	// Clear queue between benchmarks
	// clearQueue(httpC, *server, *queue)

	// Benchmark 2: Lifecycle throughput
	fmt.Println("\n=== Lifecycle Benchmark (enqueue -> fetch -> ack) ===")
	lcResult := benchLifecycle(c, httpC, *server, *jobs, *concurrency, *queue)
	printStats(lcResult)
}

func benchEnqueue(c *client.Client, total, concurrency int, queue string) benchResult {
	lats := make([]time.Duration, total)
	var idx atomic.Int64
	var wg sync.WaitGroup

	perWorker := total / concurrency
	remainder := total % concurrency

	start := time.Now()

	for i := range concurrency {
		n := perWorker
		if i < remainder {
			n++
		}
		wg.Add(1)
		go func(count int) {
			defer wg.Done()
			for range count {
				payload := map[string]any{"i": idx.Load()}
				opStart := time.Now()
				_, err := c.Enqueue(queue, payload)
				lat := time.Since(opStart)
				if err != nil {
					fmt.Fprintf(os.Stderr, "enqueue error: %v\n", err)
					continue
				}
				pos := idx.Add(1) - 1
				lats[pos] = lat
			}
		}(n)
	}

	wg.Wait()
	elapsed := time.Since(start)

	actual := int(idx.Load())
	fmt.Printf("  completed: %d/%d in %s\n", actual, total, elapsed.Round(time.Millisecond))
	return benchResult{lats: lats[:actual], elapsed: elapsed}
}

func benchLifecycle(c *client.Client, httpC *http.Client, serverURL string, total, concurrency int, queue string) benchResult {
	lats := make([]time.Duration, total)
	var idx atomic.Int64
	var wg sync.WaitGroup

	perWorker := total / concurrency
	remainder := total % concurrency

	start := time.Now()

	for i := range concurrency {
		n := perWorker
		if i < remainder {
			n++
		}
		workerID := fmt.Sprintf("bench-worker-%d", i)
		wg.Add(1)
		go func(count int, wid string) {
			defer wg.Done()
			for range count {
				// payload := map[string]any{"i": idx.Load()}
				opStart := time.Now()

				// // Enqueue
				// _, err := c.Enqueue(queue, payload)
				// if err != nil {
				// 	fmt.Fprintf(os.Stderr, "lifecycle enqueue error: %v\n", err)
				// 	continue
				// }

				// Fetch
				jobID, err := fetchJob(httpC, serverURL, queue, wid)
				if err != nil {
					fmt.Fprintf(os.Stderr, "lifecycle fetch error: %v\n", err)
					continue
				}
				// Sleep 1ms
				time.Sleep(1 * time.Millisecond)
				// Ack
				err = ackJob(httpC, serverURL, jobID)
				if err != nil {
					fmt.Fprintf(os.Stderr, "lifecycle ack error: %v\n", err)
					continue
				}

				lat := time.Since(opStart)
				pos := idx.Add(1) - 1
				lats[pos] = lat
			}
		}(n, workerID)
	}

	wg.Wait()
	elapsed := time.Since(start)

	actual := int(idx.Load())
	fmt.Printf("  completed: %d/%d in %s\n", actual, total, elapsed.Round(time.Millisecond))
	return benchResult{lats: lats[:actual], elapsed: elapsed}
}

func fetchJob(httpC *http.Client, serverURL, queue, workerID string) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"queues":    []string{queue},
		"worker_id": workerID,
		"hostname":  "bench-host",
		"timeout":   1,
	})
	resp, err := httpC.Post(serverURL+"/api/v1/fetch", "application/json", bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("fetch request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNoContent {
		return "", fmt.Errorf("no jobs available")
	}
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("fetch status %d: %s", resp.StatusCode, data)
	}

	var result struct {
		JobID string `json:"job_id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("fetch decode: %w", err)
	}
	return result.JobID, nil
}

func ackJob(httpC *http.Client, serverURL, jobID string) error {
	body, _ := json.Marshal(map[string]any{})
	resp, err := httpC.Post(serverURL+"/api/v1/ack/"+jobID, "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("ack request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("ack status %d: %s", resp.StatusCode, data)
	}
	return nil
}

func clearQueue(httpC *http.Client, serverURL, queue string) {
	req, _ := http.NewRequest("POST", serverURL+"/api/v1/queues/"+queue+"/clear", nil)
	resp, err := httpC.Do(req)
	if err != nil {
		return // queue may not exist yet
	}
	resp.Body.Close()
}

func printStats(r benchResult) {
	if len(r.lats) == 0 {
		fmt.Println("  no successful operations")
		return
	}

	slices.Sort(r.lats)

	n := len(r.lats)
	opsPerSec := float64(n) / r.elapsed.Seconds()

	var sum time.Duration
	for _, l := range r.lats {
		sum += l
	}
	avg := sum / time.Duration(n)

	p50 := r.lats[n*50/100]
	p90 := r.lats[n*90/100]
	p99 := r.lats[n*99/100]

	fmt.Printf("  ops/sec: %.1f\n", opsPerSec)
	fmt.Printf("  avg:     %s\n", avg.Round(time.Microsecond))
	fmt.Printf("  p50:     %s\n", p50.Round(time.Microsecond))
	fmt.Printf("  p90:     %s\n", p90.Round(time.Microsecond))
	fmt.Printf("  p99:     %s\n", p99.Round(time.Microsecond))
	fmt.Printf("  min:     %s\n", r.lats[0].Round(time.Microsecond))
	fmt.Printf("  max:     %s\n", r.lats[n-1].Round(time.Microsecond))
}
