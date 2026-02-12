package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func testBatchWriter(t *testing.T) (*BatchWriter, *DB) {
	t.Helper()
	db, err := Open(t.TempDir())
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	bw := NewBatchWriter(db.Write, DefaultBatchWriterConfig())
	t.Cleanup(func() { bw.Stop() })
	return bw, db
}

func TestBatchWriterBasic(t *testing.T) {
	bw, db := testBatchWriter(t)
	s := NewStoreWithWriter(db, bw)
	t.Cleanup(func() { s.Close() })

	const n = 20
	var wg sync.WaitGroup
	errs := make([]error, n)

	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(idx int) {
			defer wg.Done()
			_, err := s.Enqueue(EnqueueRequest{
				Queue:   "batch.test",
				Payload: json.RawMessage(fmt.Sprintf(`{"i":%d}`, idx)),
			})
			errs[idx] = err
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Errorf("Enqueue(%d) error: %v", i, err)
		}
	}

	var count int
	err := db.Read.QueryRow("SELECT COUNT(*) FROM jobs WHERE queue = 'batch.test'").Scan(&count)
	if err != nil {
		t.Fatalf("count query: %v", err)
	}
	if count != n {
		t.Errorf("job count = %d, want %d", count, n)
	}
}

func TestBatchWriterSingleOp(t *testing.T) {
	bw, db := testBatchWriter(t)

	err := bw.ExecuteTx(func(tx *sql.Tx) error {
		_, err := tx.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)", "single.test")
		return err
	})
	if err != nil {
		t.Fatalf("ExecuteTx() error: %v", err)
	}

	var name string
	err = db.Read.QueryRow("SELECT name FROM queues WHERE name = 'single.test'").Scan(&name)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if name != "single.test" {
		t.Errorf("name = %q, want %q", name, "single.test")
	}
}

func TestBatchWriterFailureIsolation(t *testing.T) {
	bw, db := testBatchWriter(t)

	const n = 10
	var wg sync.WaitGroup
	errs := make([]error, n)

	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(idx int) {
			defer wg.Done()
			errs[idx] = bw.ExecuteTx(func(tx *sql.Tx) error {
				if idx == 5 {
					return fmt.Errorf("intentional failure")
				}
				_, err := tx.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)",
					fmt.Sprintf("fail.test.%d", idx))
				return err
			})
		}(i)
	}
	wg.Wait()

	// Op 5 should have failed.
	if errs[5] == nil {
		t.Error("expected error for op 5, got nil")
	}

	// All other ops should have succeeded.
	for i, err := range errs {
		if i == 5 {
			continue
		}
		if err != nil {
			t.Errorf("op %d unexpected error: %v", i, err)
		}
	}

	// Verify successful ops are in DB.
	var count int
	err := db.Read.QueryRow("SELECT COUNT(*) FROM queues WHERE name LIKE 'fail.test.%'").Scan(&count)
	if err != nil {
		t.Fatalf("count query: %v", err)
	}
	if count != n-1 {
		t.Errorf("queue count = %d, want %d", count, n-1)
	}
}

func TestBatchWriterShutdownDrains(t *testing.T) {
	db, err := Open(t.TempDir())
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	// Use a large flush interval so ops stay pending until Stop() drains them.
	bw := NewBatchWriter(db.Write, BatchWriterConfig{
		MaxBatchSize:  128,
		FlushInterval: 10 * time.Second,
	})

	const n = 5
	var wg sync.WaitGroup
	errs := make([]error, n)

	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(idx int) {
			defer wg.Done()
			errs[idx] = bw.ExecuteTx(func(tx *sql.Tx) error {
				_, err := tx.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)",
					fmt.Sprintf("drain.test.%d", idx))
				return err
			})
		}(i)
	}

	// Give goroutines time to submit ops.
	time.Sleep(50 * time.Millisecond)

	// Stop should drain and flush all pending ops.
	bw.Stop()
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Errorf("op %d error: %v", i, err)
		}
	}

	var count int
	err = db.Read.QueryRow("SELECT COUNT(*) FROM queues WHERE name LIKE 'drain.test.%'").Scan(&count)
	if err != nil {
		t.Fatalf("count query: %v", err)
	}
	if count != n {
		t.Errorf("queue count = %d, want %d", count, n)
	}
}

func TestBatchWriterExecutePassthrough(t *testing.T) {
	bw, db := testBatchWriter(t)

	_, err := bw.Execute("INSERT OR IGNORE INTO queues (name) VALUES (?)", "passthrough.test")
	if err != nil {
		t.Fatalf("Execute() error: %v", err)
	}

	var name string
	err = db.Read.QueryRow("SELECT name FROM queues WHERE name = 'passthrough.test'").Scan(&name)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if name != "passthrough.test" {
		t.Errorf("name = %q, want %q", name, "passthrough.test")
	}
}

func BenchmarkEnqueueDirect(b *testing.B) {
	db, err := Open(b.TempDir())
	if err != nil {
		b.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	s := NewStore(db)
	defer s.Close()
	payload := json.RawMessage(`{"bench":true}`)

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			_, err := s.Enqueue(EnqueueRequest{
				Queue:   "bench.direct",
				Payload: payload,
			})
			if err != nil {
				b.Errorf("Enqueue() error: %v", err)
			}
		}
	})
}

func BenchmarkEnqueueBatched(b *testing.B) {
	db, err := Open(b.TempDir())
	if err != nil {
		b.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	bw := NewBatchWriter(db.Write, DefaultBatchWriterConfig())
	defer bw.Stop()

	s := NewStoreWithWriter(db, bw)
	defer s.Close()
	payload := json.RawMessage(`{"bench":true}`)

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			_, err := s.Enqueue(EnqueueRequest{
				Queue:   "bench.batched",
				Payload: payload,
			})
			if err != nil {
				b.Errorf("Enqueue() error: %v", err)
			}
		}
	})
}

func BenchmarkBatchWriterThroughput(b *testing.B) {
	db, err := Open(b.TempDir())
	if err != nil {
		b.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	bw := NewBatchWriter(db.Write, DefaultBatchWriterConfig())
	defer bw.Stop()

	var ops atomic.Int64
	start := time.Now()

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			err := bw.ExecuteTx(func(tx *sql.Tx) error {
				_, err := tx.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)", "throughput.test")
				return err
			})
			if err != nil {
				b.Errorf("ExecuteTx() error: %v", err)
			}
			ops.Add(1)
		}
	})

	elapsed := time.Since(start)
	b.ReportMetric(float64(ops.Load())/elapsed.Seconds(), "ops/sec")
}
