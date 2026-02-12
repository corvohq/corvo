package store

import (
	"database/sql"
	"log/slog"
)

// asyncOp represents a single SQL operation to be executed asynchronously.
type asyncOp struct {
	query string
	args []any
	done chan struct{} // non-nil for flush sentinels
}

// AsyncWriter batches non-critical SQL operations (events, stats) and executes
// them in the background to keep the hot path fast.
type AsyncWriter struct {
	db      *sql.DB
	pending chan asyncOp
	stop    chan struct{}
	done    chan struct{}
}

// NewAsyncWriter creates and starts an AsyncWriter.
func NewAsyncWriter(db *sql.DB) *AsyncWriter {
	aw := &AsyncWriter{
		db:      db,
		pending: make(chan asyncOp, 4096),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
	}
	go aw.loop()
	return aw
}

// Emit queues a SQL operation for async execution.
// If the channel is full, the op is dropped (events/stats are non-critical).
func (aw *AsyncWriter) Emit(query string, args ...any) {
	select {
	case aw.pending <- asyncOp{query: query, args: args}:
	default:
		slog.Debug("async writer: channel full, dropping op")
	}
}

// Flush blocks until all currently pending operations have been executed.
func (aw *AsyncWriter) Flush() {
	done := make(chan struct{})
	aw.pending <- asyncOp{done: done}
	<-done
}

// Stop drains pending operations, flushes them, and returns.
func (aw *AsyncWriter) Stop() {
	close(aw.stop)
	<-aw.done
}

func (aw *AsyncWriter) loop() {
	defer close(aw.done)

	batch := make([]asyncOp, 0, 256)

	for {
		select {
		case op := <-aw.pending:
			batch = append(batch, op)
		case <-aw.stop:
			aw.drain(&batch)
			aw.flushBatch(batch)
			return
		}

		// Non-blocking drain up to 256 ops.
		for len(batch) < 256 {
			select {
			case op := <-aw.pending:
				batch = append(batch, op)
			default:
				goto flush
			}
		}

	flush:
		aw.flushBatch(batch)
		batch = batch[:0]
	}
}

func (aw *AsyncWriter) drain(batch *[]asyncOp) {
	for {
		select {
		case op := <-aw.pending:
			*batch = append(*batch, op)
		default:
			return
		}
	}
}

func (aw *AsyncWriter) flushBatch(batch []asyncOp) {
	if len(batch) == 0 {
		return
	}

	var ops []asyncOp
	var flushSignals []chan struct{}
	for _, op := range batch {
		if op.done != nil {
			flushSignals = append(flushSignals, op.done)
		} else {
			ops = append(ops, op)
		}
	}

	if len(ops) > 0 {
		tx, err := aw.db.Begin()
		if err != nil {
			slog.Error("async writer: begin tx", "error", err)
		} else {
			for _, op := range ops {
				if _, err := tx.Exec(op.query, op.args...); err != nil {
					slog.Debug("async writer: exec error", "error", err, "query", op.query)
				}
			}
			if err := tx.Commit(); err != nil {
				slog.Error("async writer: commit", "error", err)
			}
		}
	}

	for _, ch := range flushSignals {
		close(ch)
	}
}
