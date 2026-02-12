package store

import (
	"testing"
	"time"
)

func TestAsyncWriterEmitAndFlush(t *testing.T) {
	db, err := Open(t.TempDir())
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	aw := NewAsyncWriter(db.Write)
	defer aw.Stop()

	// Emit some queue inserts
	aw.Emit("INSERT OR IGNORE INTO queues (name) VALUES (?)", "async.q1")
	aw.Emit("INSERT OR IGNORE INTO queues (name) VALUES (?)", "async.q2")
	aw.Emit("INSERT OR IGNORE INTO queues (name) VALUES (?)", "async.q3")

	// Flush to ensure they're written
	aw.Flush()

	var count int
	err = db.Read.QueryRow("SELECT COUNT(*) FROM queues WHERE name LIKE 'async.q%'").Scan(&count)
	if err != nil {
		t.Fatalf("count query: %v", err)
	}
	if count != 3 {
		t.Errorf("queue count = %d, want 3", count)
	}
}

func TestAsyncWriterBatchExecution(t *testing.T) {
	db, err := Open(t.TempDir())
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	aw := NewAsyncWriter(db.Write)
	defer aw.Stop()

	// Emit many ops to test batching
	for i := range 100 {
		aw.Emit("INSERT INTO queue_stats (queue, enqueued) VALUES (?, 1) ON CONFLICT(queue) DO UPDATE SET enqueued = enqueued + 1",
			"batch.stats")
		_ = i
	}

	aw.Flush()

	var enqueued int
	err = db.Read.QueryRow("SELECT enqueued FROM queue_stats WHERE queue = 'batch.stats'").Scan(&enqueued)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if enqueued != 100 {
		t.Errorf("enqueued = %d, want 100", enqueued)
	}
}

func TestAsyncWriterStopDrains(t *testing.T) {
	db, err := Open(t.TempDir())
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	aw := NewAsyncWriter(db.Write)

	// Emit ops then immediately stop — should drain all pending
	aw.Emit("INSERT OR IGNORE INTO queues (name) VALUES (?)", "drain.q1")
	aw.Emit("INSERT OR IGNORE INTO queues (name) VALUES (?)", "drain.q2")

	aw.Stop()

	var count int
	err = db.Read.QueryRow("SELECT COUNT(*) FROM queues WHERE name LIKE 'drain.q%'").Scan(&count)
	if err != nil {
		t.Fatalf("count query: %v", err)
	}
	if count != 2 {
		t.Errorf("queue count = %d, want 2", count)
	}
}

func TestAsyncWriterDropsWhenFull(t *testing.T) {
	db, err := Open(t.TempDir())
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	// Create writer but don't start the loop — channel will fill up.
	// We test the Emit behavior by creating a writer with a tiny channel.
	aw := &AsyncWriter{
		db:      db.Write,
		pending: make(chan asyncOp, 2), // very small buffer
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
	}
	go aw.loop()
	defer aw.Stop()

	// Give the loop time to start and block waiting for ops
	time.Sleep(10 * time.Millisecond)

	// Fill beyond capacity — some should be silently dropped
	for range 100 {
		aw.Emit("INSERT OR IGNORE INTO queues (name) VALUES (?)", "full.q")
	}

	// Flush what made it through
	aw.Flush()

	// We just verify no panic and some ops executed.
	// Exact count depends on timing.
	var count int
	db.Read.QueryRow("SELECT COUNT(*) FROM queues WHERE name = 'full.q'").Scan(&count)
	if count == 0 {
		t.Error("expected at least some ops to succeed")
	}
}

func TestAsyncWriterEventInsert(t *testing.T) {
	db, err := Open(t.TempDir())
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	// Need a queue and job for the event FK
	db.Write.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)", "event.q")
	db.Write.Exec("INSERT INTO jobs (id, queue, state, payload, priority) VALUES ('j1', 'event.q', 'pending', '{}', 2)")

	aw := NewAsyncWriter(db.Write)
	defer aw.Stop()

	aw.Emit("INSERT INTO events (type, job_id, queue) VALUES ('enqueued', ?, ?)", "j1", "event.q")
	aw.Emit("INSERT INTO events (type, job_id, queue) VALUES ('started', ?, ?)", "j1", "event.q")
	aw.Flush()

	var count int
	err = db.Read.QueryRow("SELECT COUNT(*) FROM events WHERE job_id = 'j1'").Scan(&count)
	if err != nil {
		t.Fatalf("count query: %v", err)
	}
	if count != 2 {
		t.Errorf("event count = %d, want 2", count)
	}
}
