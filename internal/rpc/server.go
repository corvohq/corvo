package rpc

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"strings"
	"sync"

	"github.com/user/corvo/internal/store"
)

// Server is a lightweight RESP-compatible TCP server for high-throughput enqueue.
type Server struct {
	store    *store.Store
	mu       sync.RWMutex
	listener net.Listener
	addr     string
	wg       sync.WaitGroup
	quit     chan struct{}
}

// New creates a new RPC server.
func New(s *store.Store, addr string) *Server {
	return &Server{
		store: s,
		addr:  addr,
		quit:  make(chan struct{}),
	}
}

// Start begins listening and accepting connections. Blocks until the listener is closed.
func (s *Server) Start() error {
	ln, err := net.Listen("tcp", s.addr)
	if err != nil {
		return fmt.Errorf("rpc listen: %w", err)
	}
	s.mu.Lock()
	s.listener = ln
	s.mu.Unlock()
	slog.Info("RPC server listening", "addr", ln.Addr().String())

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-s.quit:
				return nil
			default:
				slog.Error("RPC accept error", "error", err)
				continue
			}
		}
		s.wg.Add(1)
		go s.handleConn(conn)
	}
}

// Addr returns the listener address. Only valid after Start is called.
func (s *Server) Addr() net.Addr {
	s.mu.RLock()
	ln := s.listener
	s.mu.RUnlock()
	if ln == nil {
		return nil
	}
	return ln.Addr()
}

// Shutdown gracefully stops the server, closing the listener and waiting for connections to drain.
func (s *Server) Shutdown() error {
	close(s.quit)
	s.mu.RLock()
	ln := s.listener
	s.mu.RUnlock()
	if ln != nil {
		ln.Close()
	}
	s.wg.Wait()
	return nil
}

func (s *Server) handleConn(conn net.Conn) {
	defer s.wg.Done()
	defer conn.Close()

	scanner := bufio.NewScanner(conn)
	// Allow up to 1MB lines for large payloads.
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)

	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}

		cmd, rest := splitFirst(line)
		switch strings.ToUpper(cmd) {
		case "PING":
			fmt.Fprintf(conn, "+PONG\r\n")

		case "ENQUEUE":
			queue, payload := splitFirst(rest)
			if queue == "" || payload == "" {
				fmt.Fprintf(conn, "-ERR usage: ENQUEUE <queue> <json_payload>\r\n")
				continue
			}
			result, err := s.store.Enqueue(store.EnqueueRequest{
				Queue:   queue,
				Payload: json.RawMessage(payload),
			})
			if err != nil {
				fmt.Fprintf(conn, "-ERR %s\r\n", err.Error())
				continue
			}
			fmt.Fprintf(conn, "+%s\r\n", result.JobID)

		default:
			fmt.Fprintf(conn, "-ERR unknown command '%s'\r\n", cmd)
		}
	}
}

// splitFirst splits s into the first space-delimited word and the rest of the string.
func splitFirst(s string) (string, string) {
	i := strings.IndexByte(s, ' ')
	if i < 0 {
		return s, ""
	}
	return s[:i], s[i+1:]
}
