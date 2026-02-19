package raft

import (
	"bytes"
	"encoding/binary"
	"fmt"

	"github.com/cockroachdb/pebble"
	"github.com/hashicorp/raft"
)

const (
	pebbleRaftLogPrefix    = "l|"
	pebbleRaftStablePrefix = "s|"
)

type pebbleRaftStore struct {
	db     *pebble.DB
	noSync bool
}

func openPebbleRaftStore(raftDir string, noSync bool) (*pebbleRaftStore, error) {
	db, err := pebble.Open(raftDir+"/pebble", &pebble.Options{
		MemTableSize:          16 << 20, // 16MB
		L0CompactionThreshold: 8,
		MaxConcurrentCompactions: func() int {
			return 2
		},
	})
	if err != nil {
		return nil, fmt.Errorf("open pebble raft store: %w", err)
	}
	return &pebbleRaftStore{db: db, noSync: noSync}, nil
}

func (s *pebbleRaftStore) syncOpt() *pebble.WriteOptions {
	if s.noSync {
		return pebble.NoSync
	}
	return pebble.Sync
}

func (s *pebbleRaftStore) Close() error {
	return s.db.Close()
}

func (s *pebbleRaftStore) FirstIndex() (uint64, error) {
	lower := []byte(pebbleRaftLogPrefix)
	upper := raftStorePrefixUpperBound(lower)
	iter, err := s.db.NewIter(&pebble.IterOptions{LowerBound: lower, UpperBound: upper})
	if err != nil {
		return 0, err
	}
	defer func() { _ = iter.Close() }()
	if !iter.First() {
		return 0, iter.Error()
	}
	return decodeIndexFromPebbleLogKey(iter.Key()), nil
}

func (s *pebbleRaftStore) LastIndex() (uint64, error) {
	lower := []byte(pebbleRaftLogPrefix)
	upper := raftStorePrefixUpperBound(lower)
	iter, err := s.db.NewIter(&pebble.IterOptions{LowerBound: lower, UpperBound: upper})
	if err != nil {
		return 0, err
	}
	defer func() { _ = iter.Close() }()
	if !iter.Last() {
		return 0, iter.Error()
	}
	return decodeIndexFromPebbleLogKey(iter.Key()), nil
}

func (s *pebbleRaftStore) GetLog(index uint64, out *raft.Log) error {
	v, closer, err := s.db.Get(pebbleRaftLogKey(index))
	if err != nil {
		if err == pebble.ErrNotFound {
			return raft.ErrLogNotFound
		}
		return err
	}
	defer func() { _ = closer.Close() }()
	l, err := decodeRaftLog(v)
	if err != nil {
		return err
	}
	*out = l
	return nil
}

func (s *pebbleRaftStore) StoreLog(log *raft.Log) error {
	return s.StoreLogs([]*raft.Log{log})
}

func (s *pebbleRaftStore) StoreLogs(logs []*raft.Log) error {
	if len(logs) == 0 {
		return nil
	}
	batch := s.db.NewBatch()
	defer func() { _ = batch.Close() }()
	for _, l := range logs {
		enc, err := encodeRaftLog(l)
		if err != nil {
			return err
		}
		if err := batch.Set(pebbleRaftLogKey(l.Index), enc, pebble.NoSync); err != nil {
			return err
		}
	}
	return batch.Commit(s.syncOpt())
}

func (s *pebbleRaftStore) DeleteRange(min, max uint64) error {
	if min > max {
		return nil
	}
	batch := s.db.NewBatch()
	defer func() { _ = batch.Close() }()
	for i := min; i <= max; i++ {
		if err := batch.Delete(pebbleRaftLogKey(i), pebble.NoSync); err != nil && err != pebble.ErrNotFound {
			return err
		}
		if i == ^uint64(0) {
			break
		}
	}
	return batch.Commit(s.syncOpt())
}

func (s *pebbleRaftStore) Set(key []byte, val []byte) error {
	return s.db.Set(pebbleRaftStableKey(key), val, s.syncOpt())
}

func (s *pebbleRaftStore) Get(key []byte) ([]byte, error) {
	v, closer, err := s.db.Get(pebbleRaftStableKey(key))
	if err != nil {
		if err == pebble.ErrNotFound {
			return []byte{}, nil
		}
		return nil, err
	}
	defer func() { _ = closer.Close() }()
	out := append([]byte(nil), v...)
	return out, nil
}

func (s *pebbleRaftStore) SetUint64(key []byte, val uint64) error {
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], val)
	return s.Set(key, buf[:])
}

func (s *pebbleRaftStore) GetUint64(key []byte) (uint64, error) {
	v, err := s.Get(key)
	if err != nil {
		return 0, err
	}
	if len(v) == 0 {
		return 0, nil
	}
	if len(v) != 8 {
		return 0, fmt.Errorf("bad stable uint64 length: %d", len(v))
	}
	return binary.BigEndian.Uint64(v), nil
}

func pebbleRaftLogKey(index uint64) []byte {
	k := make([]byte, len(pebbleRaftLogPrefix)+8)
	copy(k, pebbleRaftLogPrefix)
	binary.BigEndian.PutUint64(k[len(pebbleRaftLogPrefix):], index)
	return k
}

func decodeIndexFromPebbleLogKey(k []byte) uint64 {
	if len(k) < len(pebbleRaftLogPrefix)+8 {
		return 0
	}
	return binary.BigEndian.Uint64(k[len(pebbleRaftLogPrefix):])
}

func pebbleRaftStableKey(key []byte) []byte {
	k := make([]byte, len(pebbleRaftStablePrefix)+len(key))
	copy(k, pebbleRaftStablePrefix)
	copy(k[len(pebbleRaftStablePrefix):], key)
	return k
}

func raftStorePrefixUpperBound(prefix []byte) []byte {
	if len(prefix) == 0 {
		return nil
	}
	b := append([]byte(nil), prefix...)
	for i := len(b) - 1; i >= 0; i-- {
		if b[i] < 0xFF {
			b[i]++
			return b[:i+1]
		}
	}
	return append(append([]byte(nil), prefix...), bytes.Repeat([]byte{0xFF}, 8)...)
}
