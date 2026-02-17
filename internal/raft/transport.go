package raft

import (
	"fmt"
	"net"
	"time"

	"github.com/hashicorp/raft"
)

// newTCPTransport creates a Raft TCP transport.
func newTCPTransport(bindAddr, advertiseAddr string) (*raft.NetworkTransport, error) {
	bind, err := net.ResolveTCPAddr("tcp", bindAddr)
	if err != nil {
		return nil, err
	}

	advertise, err := resolveAdvertiseAddr(bind, advertiseAddr)
	if err != nil {
		return nil, err
	}

	transport, err := raft.NewTCPTransport(
		bind.String(),
		advertise,
		8,              // maxPool
		10*time.Second, // timeout
		nil,            // logOutput (uses default logger)
	)
	if err != nil {
		return nil, err
	}

	return transport, nil
}

func resolveAdvertiseAddr(bind *net.TCPAddr, advertiseAddr string) (*net.TCPAddr, error) {
	if advertiseAddr != "" {
		return net.ResolveTCPAddr("tcp", advertiseAddr)
	}

	if bind == nil {
		return nil, fmt.Errorf("invalid raft bind address")
	}

	// Raft cannot advertise wildcard addresses. For local dev defaults like
	// ":9000"/"0.0.0.0:9000", advertise loopback unless explicitly overridden.
	if bind.IP == nil || bind.IP.IsUnspecified() {
		return &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: bind.Port}, nil
	}

	return bind, nil
}
