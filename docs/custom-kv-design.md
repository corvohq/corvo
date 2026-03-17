# Custom KV Store Design

Purpose-built B+ tree for corvo. Replaces Pebble behind the `kv.Store` interface.

## Why not Pebble?

Pebble is a general-purpose LSM tree that carries machinery corvo doesn't need:
- **WAL** — Raft is the log
- **LSM compaction** — background goroutines, write amplification, space amplification
- **Block cache** — corvo's values are 72 bytes, not 4KB blocks
- **Bloom filters** — key prefixes are known, not random
- **MVCC / snapshots** — FSM is single-threaded
- **Concurrent write support** — FSM is single-threaded

Corvo's constraints make a much simpler engine viable:
- Single writer (FSM is serial)
- No WAL needed (Raft handles durability)
- No fsync on writes (`pebbleNoSync=true` today)
- Known key layout (fixed prefixes, ULID suffixes)
- Small values (72-byte job headers, small index entries)
- Large values (payloads up to 256KB) stored in a separate value log
- Checkpoint = flush + copy files (Raft snapshot triggers this)
- Recovery = restore snapshot files + replay Raft log

## Architecture

```
┌─────────────────────────────────────┐
│            kv.Store interface        │
│  Get() / NewBatch() / Close()       │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│           CorvoDB                    │
│  (public API, concurrency control)  │
│                                     │
│  rwmu sync.RWMutex                  │
│  tree *btree     (sorted index)     │
│  vlog *valuelog  (large values)     │
│  file *os.File   (tree pages)       │
└──────┬──────────────────┬───────────┘
       │                  │
┌──────▼──────┐    ┌──────▼──────┐
│   btree      │    │  valuelog   │
│  (B+ tree)   │    │ (append)   │
│              │    │            │
│ small values │    │  payloads  │
│ inline in    │    │  256KB max │
│ leaf pages   │    │            │
│              │    │ write-once │
│ large values │    │ read by    │
│ store vlog   │    │ offset+len │
│ pointer      │    │            │
└──────────────┘    └────────────┘
```

### Value Split: B+ Tree vs Value Log

The B+ tree stores all keys and small values (up to ~1KB) inline in leaf pages.
Large values (job payloads up to 256KB) are written to a separate append-only
value log. The leaf cell stores a `(offset, length)` pointer instead.

This split is natural for corvo's workload:
- **Hot path** (fetch/ack/retry/cancel): touches `j|` headers (72 bytes) — always inline
- **Cold path** (enqueue write, fetch delivery read): touches `jp|` payloads — value log
- Payloads are write-once and read-once — perfect for an append-only log

The threshold (~1KB) means all index keys, job headers, queue configs, worker
state, cron schedules, and enterprise settings stay inline. Only `jp|` payloads
hit the value log.

## Page Layout

4KB pages aligned to OS page size. Two node types:

### Internal Node Page
```
┌──────────────────────────────────────────────────────┐
│ Header (16 bytes)                                     │
│   flags=0x01 | count | reserved | reserved            │
├──────────────────────────────────────────────────────┤
│ Cell 0: [child_pgid:8] [key_len:2] [key_data...]     │
│ Cell 1: [child_pgid:8] [key_len:2] [key_data...]     │
│ ...                                                   │
│ Cell N: [child_pgid:8]  (rightmost child, no key)     │
├──────────────────────────────────────────────────────┤
│ Free space                                            │
└──────────────────────────────────────────────────────┘
```

With ~60-byte keys (typical for corvo), ~56 entries per internal page.
Tree depth for 10M keys: log_56(10M) ≈ 4 levels.

### Leaf Node Page
```
┌──────────────────────────────────────────────────────┐
│ Header (16 bytes)                                     │
│   flags=0x02 | count | reserved | next_leaf:8         │
├──────────────────────────────────────────────────────┤
│ Cell 0: [key_len:2] [val_len:2] [key_data] [val_data] │
│ Cell 1: [key_len:2] [val_len:2] [key_data] [val_data] │
│ ...                                                   │
├──────────────────────────────────────────────────────┤
│ Free space                                            │
└──────────────────────────────────────────────────────┘
```

With 28-byte key + 72-byte value (job header): ~38 entries per leaf page.
With 60-byte key + 0-byte value (index pointer): ~64 entries per leaf page.

### Value Log Pointers

When `val_len` exceeds the inline threshold (~1KB), the leaf cell stores a
value log pointer instead of inline data:

```
Leaf cell with vlog pointer:
  [key_len:2] [val_len:2 = 0xFFFE] [key_data] [vlog_offset:8] [vlog_length:4]

The sentinel val_len 0xFFFE signals "value is in the value log".
```

No overflow pages, no page chaining, no fragmentation from large values.
The B+ tree stays clean — every cell fits in a page.

## Value Log

Append-only file for large values. Dead simple.

```
┌──────────────────────────────────────┐
│ Header (16 bytes)                     │
│   magic: "CVLG" | version | reserved │
├──────────────────────────────────────┤
│ Entry 0: [len:4] [data...]           │
│ Entry 1: [len:4] [data...]           │
│ ...                                   │
│ (append position = next write offset) │
└──────────────────────────────────────┘
```

- **Write**: append `[len:4][data]`, return `(offset, length)`
- **Read**: pread at offset, read `len` bytes
- **No updates**: payloads are write-once
- **GC**: when jobs are purged, their vlog space becomes garbage.
  Compact by rewriting live entries (or just let Raft snapshot rebuild
  a clean vlog periodically)

### Value Log GC Strategy

The vlog accumulates garbage as jobs complete and get purged. Options:

1. **Lazy rebuild on snapshot**: during Raft snapshot, write a fresh vlog
   containing only live payload keys. The snapshot ships the clean vlog.
   Between snapshots, garbage accumulates but reads are unaffected (dead
   entries are never read).

2. **Space tracking**: track `live_bytes / total_bytes` ratio. When it drops
   below a threshold (e.g. 50%), trigger a compaction pass — scan the tree
   for all vlog pointers, rewrite live entries to a new file, update tree
   pointers, swap files.

Option 1 is simpler and aligns with existing Raft snapshot behavior.
Start with option 1, add option 2 if disk usage becomes a concern.

## Meta / Header Page

Page 0 and 1 are both meta pages (double-buffered). Updated on every commit.

```
┌──────────────────────────────────────────────────────┐
│ Magic:        "CRVO" (4 bytes)                        │
│ Version:      uint32 (1)                              │
│ PageSize:     uint32 (4096)                           │
│ PageCount:    uint64                                  │
│ RootPageID:   uint64                                  │
│ FreelistPgID: uint64                                  │
│ TxID:         uint64 (monotonic commit counter)       │
│ VlogSize:     uint64 (value log append position)      │
│ Checksum:     uint64 (xxhash of above fields)         │
│ Padding to page size                                  │
└──────────────────────────────────────────────────────┘
```

Writes alternate between page 0 and page 1. On open, read both, use the
one with the higher valid TxID + checksum. If a crash tears one meta write,
the other is still valid.

## Free List

Deleted pages go onto a free list stored as pages of `pageID` entries.
When the free list page is full, it chains to another.

On page allocation: pop from free list first, grow file only if empty.

## Operations

### Store.Get(key)

```
acquire rwmu.RLock
traverse tree root → leaf (binary search at each level)
binary search within leaf for key
if value is inline → copy value out
if value is vlog pointer → pread from value log
release rwmu.RLock
```

### Batch (buffered writes)

The batch buffers all mutations in a sorted slice.
Reads check the buffer first, then fall through to the tree.

```go
type corvoBatch struct {
    db           *CorvoDB
    writes       []mutation        // sorted by key on commit
    deleteRanges []keyRange
}

type mutation struct {
    key    []byte
    value  []byte  // nil = delete
}
```

- `Get`: linear scan buffer (small), then db.Get
- `Set/Delete`: append to buffer
- `DeleteRange`: record range, filter on Get/Iter
- `NewIter`: merge iterator over (buffer + tree)
- `Commit`: acquire rwmu.Lock, apply all mutations to tree, flush dirty pages

### Commit Path

```
1. Sort mutations by key
2. Large values → append to value log, replace value with vlog pointer
3. Acquire write lock (rwmu.Lock)
4. For each mutation:
   a. Traverse to leaf
   b. Insert/update/delete cell
   c. If leaf overflows → split (may cascade up)
   d. If leaf underflows → merge or rebalance
   e. Mark page dirty
5. Write all dirty pages to file (pwrite, no fsync)
6. Write meta page (alternating page 0/1, no fsync)
7. Clear dirty set
8. Release write lock
```

No fsync — the OS flushes pages lazily. Raft handles durability.

### Iterator (merge iterator)

For `Batch.NewIter`, a merge iterator combines:
1. Buffered writes/deletes in the batch
2. The underlying tree's leaf chain

```
tree iter:  positions at lower bound, follows next-leaf pointers
batch iter: positions in sorted buffer at lower bound
merge:      advance whichever has the smaller key, skip deletes
```

### Checkpoint (for Raft snapshots)

Called between FSM applies (single-threaded, no concurrent writes).

```
1. Flush all dirty pages (pwrite to tree file)
2. Write meta page
3. Copy tree file to snapshot path
4. Copy vlog file to snapshot path (or write a compacted vlog with live entries only)
```

Since there are no concurrent writers during checkpoint, both files are
in a consistent state after step 2. No fsync needed — if the process
crashes mid-checkpoint, Raft will just retry the snapshot later.

### Restore (from Raft snapshot)

```
1. Close current files
2. Copy snapshot tree file + vlog file into place
3. Open new files, read meta page, set root
```

## Concurrency Model

- **Single writer**: FSM goroutine holds write lock during Batch.Commit
- **Multiple readers**: Store.Get and read-only iterators hold read lock
- **No reader-writer starvation**: FSM commits are fast (sub-millisecond for
  typical batch sizes), readers rarely block

This is simpler than Pebble (which has concurrent writers, MVCC, etc.)
and simpler than bbolt (which has full MVCC with copy-on-write pages).

## File Growth

Tree file grows in 64MB chunks to reduce `ftruncate` calls.
Pre-allocated space is tracked in the free list.

Value log grows unbounded (append-only). Compacted during Raft snapshot
or when live ratio drops below threshold.

## TigerStyle

### Assertions

Every invariant is asserted, not error-checked. Internal state corruption
should crash immediately, not propagate silently.

```go
// Page operations
assert(count <= maxCellsPerPage, "leaf page %d: cell count %d exceeds max %d", pgid, count, max)
assert(freeSpace >= 0, "leaf page %d: negative free space after insert", pgid)
assert(key != nil, "btree.insert: nil key")

// Tree invariants
assert(depth > 0, "btree: zero-depth tree")
assert(root != invalidPageID, "btree: invalid root after split")

// Value log
assert(offset+length <= vlogSize, "vlog read past end: offset=%d len=%d size=%d", offset, length, vlogSize)

// Batch
assert(!committed, "batch used after commit")
```

Errors are reserved for I/O boundaries (file read/write failures).
Everything else is an invariant violation — panic with context.

### Deterministic Core

No non-determinism in the B+ tree or value log. Pure functions of input.

- No `time.Now()` — timestamps come from the FSM
- No `math/rand` — no randomness needed
- No goroutines — single-threaded write path
- No global state — all state in the `CorvoDB` struct

### Zero Allocations on Hot Path

```go
// Page traversal reuses a stack buffer for the path
type treePath [maxDepth]pathEntry  // stack-allocated, no heap

// Key comparisons use bytes.Compare directly — no string conversion
// Cell reads return slices into the page buffer — no copy until needed
// Get copies the value once on return — unavoidable but exactly once
```

### Make Illegal States Unrepresentable

```go
type pageID uint64
const invalidPageID pageID = 0  // page 0 and 1 are meta — never a data page

type pageFlags uint16
const (
    flagInternal pageFlags = 0x01
    flagLeaf     pageFlags = 0x02
)
// No zero-value flag — uninitialized pages are always invalid

type cellType uint8
const (
    cellInline cellType = 1  // value stored in leaf page
    cellVlog   cellType = 2  // value stored in value log
    cellDelete cellType = 3  // tombstone in batch buffer
)
```

### Simulator Integration

The B+ tree implements `kv.Store` — the simulator already exercises
every op through this interface. Additional invariant checks:

```go
// After every Batch.Commit, optionally verify:
func (db *CorvoDB) CheckInvariants() {
    // 1. Tree is balanced (all leaves at same depth)
    // 2. Keys are sorted within each page
    // 3. Keys are sorted across pages (separator keys correct)
    // 4. All pages reachable from root (no orphans)
    // 5. Free list pages not in tree
    // 6. Page count matches file size
    // 7. All vlog pointers reference valid offsets
    // 8. No duplicate keys across leaves
    // 9. Leaf chain covers all leaves in order
}
```

Run `CheckInvariants()` after every apply in the simulator.
Skip in production (too expensive). Enable via build tag or config flag.

### Explicit Resource Limits

```go
const (
    maxKeySize    = 512           // keys beyond this are a bug
    maxInlineVal  = 1024          // values above this go to vlog
    maxVlogEntry  = 256 * 1024    // 256KB max payload (matches server limit)
    maxPageCount  = 1 << 32       // ~16TB at 4KB pages
    maxTreeDepth  = 8             // B+ tree with 56-way branching: 56^8 > 10^13 keys
    maxBatchSize  = 1 << 20       // 1M mutations per batch — if you hit this, something is wrong
)
```

Every limit is documented with what happens when hit (assert/panic).

## What This Doesn't Have (by design)

- **No WAL** — Raft is the write-ahead log
- **No compaction** — B+ tree doesn't need it (no LSM levels)
- **No bloom filters** — key layout is known, not random
- **No block cache** — pages are small, OS page cache handles this
- **No compression** — values are 72 bytes, not worth compressing
- **No concurrent writers** — FSM is serial
- **No MVCC** — single writer, readers see committed state
- **No checksums per page** — if a page is torn, Raft restore fixes it
  (add page checksums later as a detection mechanism if needed)

## Size Estimates

1M jobs with header/payload split:
- Job headers (j|):  1M × (28 + 72) = ~100MB in leaf pages
- Pending index (p|): variable, ~50MB at peak
- Active index (a|):  ~20MB at peak
- Other indexes:      ~30MB
- Internal pages:     ~1% of leaf pages
- **Tree file: ~200MB for 1M jobs**
- Value log: depends on payload sizes (1M × 10KB avg = ~10GB)

10M jobs: ~2GB tree file + proportional vlog. Tree stays fast regardless
of vlog size — hot path never touches the vlog.

## Implementation Plan

```
internal/kv/
  corvo_db.go          # CorvoDB struct, Open(), Close(), kv.Store implementation
  corvo_batch.go       # Batch implementation, mutation buffer, merge iterator
  corvo_btree.go       # B+ tree: get, insert, delete, split, merge
  corvo_page.go        # Page encoding/decoding, cell read/write
  corvo_file.go        # File I/O, page cache, free list, meta page
  corvo_vlog.go        # Value log: append, read, compact
  corvo_check.go       # CheckInvariants() for simulator
  corvo_db_test.go     # Test against same suite as PebbleStore
```

Phases:
1. In-memory B+ tree (no persistence) — validate correctness via simulator
2. Add file persistence (pages, meta, free list)
3. Add value log for large values
4. Benchmark against Pebble via `corvo bench`
5. Run extended simulator (millions of ops, fault injection)
