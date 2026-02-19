//go:build !race

package raft

import (
	"encoding/json"
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/corvohq/corvo/internal/store"
)

func benchCluster(b *testing.B) (*Cluster, *store.Store) {
	b.Helper()
	cfg := DefaultClusterConfig()
	cfg.NodeID = "bench-node"
	cfg.DataDir = b.TempDir()
	cfg.RaftBind = benchRaftAddr(b)
	cfg.Bootstrap = true
	cfg.PebbleNoSync = true
	cfg.RaftNoSync = true

	c, err := NewCluster(cfg)
	if err != nil {
		b.Fatalf("NewCluster: %v", err)
	}
	b.Cleanup(func() { _ = c.Shutdown() })

	if err := c.WaitForLeader(5 * time.Second); err != nil {
		b.Fatalf("WaitForLeader: %v", err)
	}
	s := store.NewStore(c, c.SQLiteReadDB())
	return c, s
}

func benchMultiCluster(b *testing.B, shards int) (*MultiCluster, *store.Store) {
	b.Helper()
	cfg := DefaultClusterConfig()
	cfg.NodeID = "bench-multi"
	cfg.DataDir = b.TempDir()
	cfg.RaftBind = benchRaftAddr(b)
	cfg.Bootstrap = true
	cfg.PebbleNoSync = true
	cfg.RaftNoSync = true

	mc, err := NewMultiCluster(cfg, shards)
	if err != nil {
		b.Fatalf("NewMultiCluster: %v", err)
	}
	b.Cleanup(func() { _ = mc.Shutdown() })

	if err := mc.WaitForLeader(5 * time.Second); err != nil {
		b.Fatalf("WaitForLeader: %v", err)
	}
	s := store.NewStore(mc, mc.SQLiteReadDB())
	return mc, s
}

func benchRaftAddr(b *testing.B) string {
	b.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		b.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()
	return addr
}

func BenchmarkEnqueueDirect(b *testing.B) {
	da, err := NewDirectApplier(b.TempDir())
	if err != nil {
		b.Fatalf("NewDirectApplier: %v", err)
	}
	b.Cleanup(func() { _ = da.Close() })

	s := store.NewStore(da, da.SQLiteDB())
	payload := json.RawMessage(`{"bench":true}`)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := s.Enqueue(store.EnqueueRequest{
			Queue:   "bench.direct",
			Payload: payload,
		})
		if err != nil {
			b.Fatalf("Enqueue: %v", err)
		}
	}
}

func BenchmarkEnqueueRaft(b *testing.B) {
	_, s := benchCluster(b)
	payload := json.RawMessage(`{"bench":true}`)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := s.Enqueue(store.EnqueueRequest{
			Queue:   "bench.raft",
			Payload: payload,
		})
		if err != nil {
			b.Fatalf("Enqueue: %v", err)
		}
	}
}

func BenchmarkEnqueueBatchRaft(b *testing.B) {
	_, s := benchCluster(b)
	payload := json.RawMessage(`{"bench":true}`)

	jobs := make([]store.EnqueueRequest, 64)
	for i := range jobs {
		jobs[i] = store.EnqueueRequest{
			Queue:   "bench.batch",
			Payload: payload,
		}
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := s.EnqueueBatch(store.BatchEnqueueRequest{Jobs: jobs})
		if err != nil {
			b.Fatalf("EnqueueBatch: %v", err)
		}
	}
}

func BenchmarkLifecycleRaft(b *testing.B) {
	_, s := benchCluster(b)
	payload := json.RawMessage(`{"bench":true}`)

	// Pre-enqueue b.N jobs before starting the timer.
	for i := 0; i < b.N; i++ {
		_, err := s.Enqueue(store.EnqueueRequest{
			Queue:   "bench.lifecycle",
			Payload: payload,
		})
		if err != nil {
			b.Fatalf("pre-enqueue %d: %v", i, err)
		}
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		fr, err := s.Fetch(store.FetchRequest{
			Queues:   []string{"bench.lifecycle"},
			WorkerID: "bench-worker",
		})
		if err != nil {
			b.Fatalf("Fetch %d: %v", i, err)
		}
		if fr == nil {
			b.Fatalf("Fetch %d: no job available", i)
		}
		if err := s.Ack(fr.JobID, json.RawMessage(`{"ok":true}`)); err != nil {
			b.Fatalf("Ack %d: %v", i, err)
		}
	}
}

func BenchmarkMultiShardEnqueue(b *testing.B) {
	for _, shards := range []int{2, 4} {
		b.Run(fmt.Sprintf("shards-%d", shards), func(b *testing.B) {
			_, s := benchMultiCluster(b, shards)
			payload := json.RawMessage(`{"bench":true}`)

			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				queue := fmt.Sprintf("bench.shard.%d", i%8)
				_, err := s.Enqueue(store.EnqueueRequest{
					Queue:   queue,
					Payload: payload,
				})
				if err != nil {
					b.Fatalf("Enqueue: %v", err)
				}
			}
		})
	}
}

func BenchmarkMultiShardLifecycle(b *testing.B) {
	for _, shards := range []int{2, 4} {
		b.Run(fmt.Sprintf("shards-%d", shards), func(b *testing.B) {
			_, s := benchMultiCluster(b, shards)
			payload := json.RawMessage(`{"bench":true}`)
			queues := []string{"bench.ms.a", "bench.ms.b", "bench.ms.c", "bench.ms.d",
				"bench.ms.e", "bench.ms.f", "bench.ms.g", "bench.ms.h"}

			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				queue := queues[i%len(queues)]
				_, err := s.Enqueue(store.EnqueueRequest{
					Queue:   queue,
					Payload: payload,
				})
				if err != nil {
					b.Fatalf("Enqueue %d: %v", i, err)
				}
				fr, err := s.Fetch(store.FetchRequest{
					Queues:   []string{queue},
					WorkerID: "bench-worker",
				})
				if err != nil {
					b.Fatalf("Fetch %d: %v", i, err)
				}
				if fr == nil {
					b.Fatalf("Fetch %d: no job available", i)
				}
				if err := s.Ack(fr.JobID, json.RawMessage(`{"ok":true}`)); err != nil {
					b.Fatalf("Ack %d: %v", i, err)
				}
			}
		})
	}
}
