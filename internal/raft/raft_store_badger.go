package raft

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"path/filepath"
	"time"

	"github.com/dgraph-io/badger/v4"
	"github.com/hashicorp/raft"
)

const (
	badgerLogPrefix    = "l|"
	badgerStablePrefix = "s|"
)

type badgerRaftStore struct {
	db *badger.DB
}

func openBadgerRaftStore(raftDir string, noSync bool) (*badgerRaftStore, error) {
	opts := badger.DefaultOptions(filepath.Join(raftDir, "badger"))
	opts.Logger = nil
	opts.SyncWrites = !noSync
	db, err := badger.Open(opts)
	if err != nil {
		return nil, fmt.Errorf("open badger raft store: %w", err)
	}
	return &badgerRaftStore{db: db}, nil
}

func (s *badgerRaftStore) Close() error {
	return s.db.Close()
}

func (s *badgerRaftStore) FirstIndex() (uint64, error) {
	var first uint64
	err := s.db.View(func(txn *badger.Txn) error {
		it := txn.NewIterator(badger.DefaultIteratorOptions)
		defer it.Close()
		prefix := []byte(badgerLogPrefix)
		for it.Seek(prefix); it.Valid(); it.Next() {
			item := it.Item()
			k := item.Key()
			if !bytes.HasPrefix(k, prefix) {
				break
			}
			first = decodeIndexFromLogKey(k)
			return nil
		}
		return nil
	})
	return first, err
}

func (s *badgerRaftStore) LastIndex() (uint64, error) {
	var last uint64
	err := s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Reverse = true
		it := txn.NewIterator(opts)
		defer it.Close()
		max := append([]byte(badgerLogPrefix), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)
		prefix := []byte(badgerLogPrefix)
		for it.Seek(max); it.Valid(); it.Next() {
			item := it.Item()
			k := item.Key()
			if !bytes.HasPrefix(k, prefix) {
				continue
			}
			last = decodeIndexFromLogKey(k)
			return nil
		}
		return nil
	})
	return last, err
}

func (s *badgerRaftStore) GetLog(index uint64, out *raft.Log) error {
	return s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(logKey(index))
		if err != nil {
			if err == badger.ErrKeyNotFound {
				return raft.ErrLogNotFound
			}
			return err
		}
		return item.Value(func(v []byte) error {
			l, err := decodeRaftLog(v)
			if err != nil {
				return err
			}
			*out = l
			return nil
		})
	})
}

func (s *badgerRaftStore) StoreLog(log *raft.Log) error {
	return s.StoreLogs([]*raft.Log{log})
}

func (s *badgerRaftStore) StoreLogs(logs []*raft.Log) error {
	if len(logs) == 0 {
		return nil
	}
	return s.db.Update(func(txn *badger.Txn) error {
		for _, l := range logs {
			enc, err := encodeRaftLog(l)
			if err != nil {
				return err
			}
			if err := txn.Set(logKey(l.Index), enc); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *badgerRaftStore) DeleteRange(min, max uint64) error {
	if min > max {
		return nil
	}
	// Split into sub-transactions to stay under Badger's ~6.5MB txn limit.
	const batchSize uint64 = 256
	for start := min; start <= max; start += batchSize {
		end := start + batchSize - 1
		if end > max || end < start { // overflow guard
			end = max
		}
		if err := s.db.Update(func(txn *badger.Txn) error {
			for i := start; i <= end; i++ {
				if err := txn.Delete(logKey(i)); err != nil && err != badger.ErrKeyNotFound {
					return err
				}
				if i == ^uint64(0) {
					break
				}
			}
			return nil
		}); err != nil {
			return err
		}
		if end == max || end == ^uint64(0) {
			break
		}
	}
	return nil
}

func (s *badgerRaftStore) Set(key []byte, val []byte) error {
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Set(stableKey(key), val)
	})
}

func (s *badgerRaftStore) Get(key []byte) ([]byte, error) {
	var out []byte
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(stableKey(key))
		if err != nil {
			if err == badger.ErrKeyNotFound {
				out = []byte{}
				return nil
			}
			return err
		}
		return item.Value(func(v []byte) error {
			out = append([]byte(nil), v...)
			return nil
		})
	})
	return out, err
}

func (s *badgerRaftStore) SetUint64(key []byte, val uint64) error {
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], val)
	return s.Set(key, buf[:])
}

func (s *badgerRaftStore) GetUint64(key []byte) (uint64, error) {
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

func logKey(index uint64) []byte {
	k := make([]byte, len(badgerLogPrefix)+8)
	copy(k, badgerLogPrefix)
	binary.BigEndian.PutUint64(k[len(badgerLogPrefix):], index)
	return k
}

func decodeIndexFromLogKey(k []byte) uint64 {
	if len(k) < len(badgerLogPrefix)+8 {
		return 0
	}
	return binary.BigEndian.Uint64(k[len(badgerLogPrefix):])
}

func stableKey(key []byte) []byte {
	k := make([]byte, len(badgerStablePrefix)+len(key))
	copy(k, badgerStablePrefix)
	copy(k[len(badgerStablePrefix):], key)
	return k
}

func encodeRaftLog(l *raft.Log) ([]byte, error) {
	var buf bytes.Buffer
	buf.Grow(1 + 8 + 8 + 1 + 8 + len(l.Data) + 8 + len(l.Extensions) + 8)
	buf.WriteByte(1)
	var tmp [8]byte
	binary.BigEndian.PutUint64(tmp[:], l.Index)
	buf.Write(tmp[:])
	binary.BigEndian.PutUint64(tmp[:], l.Term)
	buf.Write(tmp[:])
	buf.WriteByte(byte(l.Type))
	binary.BigEndian.PutUint64(tmp[:], uint64(len(l.Data)))
	buf.Write(tmp[:])
	buf.Write(l.Data)
	binary.BigEndian.PutUint64(tmp[:], uint64(len(l.Extensions)))
	buf.Write(tmp[:])
	buf.Write(l.Extensions)
	binary.BigEndian.PutUint64(tmp[:], uint64(l.AppendedAt.UnixNano()))
	buf.Write(tmp[:])
	return buf.Bytes(), nil
}

func decodeRaftLog(data []byte) (raft.Log, error) {
	var l raft.Log
	r := bytes.NewReader(data)
	version, err := r.ReadByte()
	if err != nil {
		return l, fmt.Errorf("decode raft log version: %w", err)
	}
	if version != 1 {
		return l, fmt.Errorf("unsupported raft log version: %d", version)
	}
	var idx uint64
	if err := binary.Read(r, binary.BigEndian, &idx); err != nil {
		return l, fmt.Errorf("decode index: %w", err)
	}
	l.Index = idx
	var term uint64
	if err := binary.Read(r, binary.BigEndian, &term); err != nil {
		return l, fmt.Errorf("decode term: %w", err)
	}
	l.Term = term
	t, err := r.ReadByte()
	if err != nil {
		return l, fmt.Errorf("decode type: %w", err)
	}
	l.Type = raft.LogType(t)
	var dataLen uint64
	if err := binary.Read(r, binary.BigEndian, &dataLen); err != nil {
		return l, fmt.Errorf("decode data len: %w", err)
	}
	l.Data = make([]byte, dataLen)
	if _, err := io.ReadFull(r, l.Data); err != nil {
		return l, fmt.Errorf("decode data: %w", err)
	}
	var extLen uint64
	if err := binary.Read(r, binary.BigEndian, &extLen); err != nil {
		return l, fmt.Errorf("decode ext len: %w", err)
	}
	l.Extensions = make([]byte, extLen)
	if _, err := io.ReadFull(r, l.Extensions); err != nil {
		return l, fmt.Errorf("decode extensions: %w", err)
	}
	var appendedNs uint64
	if err := binary.Read(r, binary.BigEndian, &appendedNs); err != nil {
		return l, fmt.Errorf("decode appended at: %w", err)
	}
	if appendedNs != 0 {
		l.AppendedAt = time.Unix(0, int64(appendedNs))
	}
	return l, nil
}
