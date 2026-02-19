package rpc

import (
	"bufio"
	"fmt"
	"net"
	"sync"
	"testing"

	"github.com/corvohq/corvo/internal/raft"
	"github.com/corvohq/corvo/internal/store"
)

func setupTest(t *testing.T) (*Server, *store.Store) {
	t.Helper()
	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	t.Cleanup(func() { _ = da.Close() })

	s := store.NewStore(da, da.SQLiteDB())
	t.Cleanup(func() { _ = s.Close() })

	srv := New(s, "127.0.0.1:0")
	errCh := make(chan error, 1)
	go func() { errCh <- srv.Start() }()

	// Wait for listener to be ready.
	for srv.Addr() == nil {
	}

	t.Cleanup(func() { _ = srv.Shutdown() })
	return srv, s
}

func dial(t *testing.T, srv *Server) net.Conn {
	t.Helper()
	conn, err := net.Dial("tcp", srv.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func sendRecv(t *testing.T, conn net.Conn, cmd string) string {
	t.Helper()
	_, _ = fmt.Fprintf(conn, "%s\n", cmd)
	scanner := bufio.NewScanner(conn)
	if !scanner.Scan() {
		t.Fatalf("no response for %q: %v", cmd, scanner.Err())
	}
	return scanner.Text()
}

func TestPing(t *testing.T) {
	srv, _ := setupTest(t)
	conn := dial(t, srv)

	resp := sendRecv(t, conn, "PING")
	if resp != "+PONG" {
		t.Fatalf("expected +PONG, got %q", resp)
	}
}

func TestEnqueue(t *testing.T) {
	srv, s := setupTest(t)
	conn := dial(t, srv)

	resp := sendRecv(t, conn, `ENQUEUE test.q {"task":"hello"}`)
	if resp[0] != '+' {
		t.Fatalf("expected +jobid, got %q", resp)
	}
	jobID := resp[1:]

	// Flush to ensure the job is written.
	s.FlushAsync()

	// Verify the job exists in the DB.
	var count int
	err := s.ReadDB().QueryRow("SELECT COUNT(*) FROM jobs WHERE id = ?", jobID).Scan(&count)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected 1 job, got %d", count)
	}
}

func TestUnknownCommand(t *testing.T) {
	srv, _ := setupTest(t)
	conn := dial(t, srv)

	resp := sendRecv(t, conn, "FOOBAR")
	if resp[:4] != "-ERR" {
		t.Fatalf("expected -ERR, got %q", resp)
	}
}

func TestConcurrent(t *testing.T) {
	srv, s := setupTest(t)
	const workers = 10
	const perWorker = 100

	var wg sync.WaitGroup
	var errors int64

	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := net.Dial("tcp", srv.Addr().String())
			if err != nil {
				t.Errorf("dial: %v", err)
				return
			}
			defer func() { _ = conn.Close() }()

			scanner := bufio.NewScanner(conn)
			for i := range perWorker {
				_, _ = fmt.Fprintf(conn, "ENQUEUE conc.q {\"i\":%d}\n", i)
				if !scanner.Scan() {
					t.Errorf("no response: %v", scanner.Err())
					return
				}
				resp := scanner.Text()
				if resp[0] != '+' {
					t.Errorf("expected +jobid, got %q", resp)
				}
			}
		}()
	}

	wg.Wait()

	if errors > 0 {
		t.Fatalf("%d errors", errors)
	}

	s.FlushAsync()

	var count int
	err := s.ReadDB().QueryRow("SELECT COUNT(*) FROM jobs WHERE queue = 'conc.q'").Scan(&count)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if count != workers*perWorker {
		t.Fatalf("expected %d jobs, got %d", workers*perWorker, count)
	}
}
