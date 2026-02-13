package raft

import (
	"fmt"
	"io"
	"path/filepath"

	"github.com/hashicorp/raft"
	raftboltdb "github.com/hashicorp/raft-boltdb/v2"
)

type raftStore interface {
	raft.LogStore
	raft.StableStore
	io.Closer
}

func openRaftStore(raftDir string, cfg ClusterConfig) (raftStore, error) {
	switch cfg.RaftStore {
	case "bolt":
		boltPath := filepath.Join(raftDir, "raft.db")
		store, err := raftboltdb.New(raftboltdb.Options{
			Path:   boltPath,
			NoSync: cfg.RaftNoSync,
		})
		if err != nil {
			return nil, fmt.Errorf("create bolt raft store: %w", err)
		}
		return store, nil
	case "badger":
		store, err := openBadgerRaftStore(raftDir, cfg.RaftNoSync)
		if err != nil {
			return nil, fmt.Errorf("create badger raft store: %w", err)
		}
		return store, nil
	case "pebble":
		store, err := openPebbleRaftStore(raftDir, cfg.RaftNoSync)
		if err != nil {
			return nil, fmt.Errorf("create pebble raft store: %w", err)
		}
		return store, nil
	default:
		return nil, fmt.Errorf("unsupported raft store %q (expected bolt, badger, or pebble)", cfg.RaftStore)
	}
}
