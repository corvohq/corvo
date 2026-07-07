# Corvo Hardening Roadmap

Tracking doc for the correctness/durability/security hardening effort started
2026-07-06 after a full three-repo review (corvo + talon + zig-raft). Ordered by
the sequence agreed with the maintainer: **talon integrity → zig-raft consensus
safety → wire in raft → core majors**.

Legend: `[x]` done, `[~]` in progress, `[ ]` todo, `[D]` deferred/decision-needed.

---

## Guiding principle

Two separable guarantees, often conflated as "fsync/COW":

- **Integrity (crash-consistency)** — after any crash, every node's on-disk data
  is a *valid* tree, never a torn hybrid. The cluster **cannot** compensate for
  loss of this: a node that restarts with a corrupt store isn't a valid replica,
  and replication reads the leader's local store. **This is required.**
- **Freshness (fsync)** — does the *last* acked write survive power loss on *that*
  node. Synchronous replication to a quorum compensates for this, so per-commit
  fsync **can be opt-in** for clustered deployments.

Caveats to document wherever durability is claimed: replication-as-durability
requires *synchronous* repl; correlated power loss (shared PDU/rack) defeats it
unless nodes span failure domains or the leader fsyncs.

---

## DONE (2026-07-06, committed on `hardening/review-fixes` + SDK `hardening/rpc-auth`)

Full build + test suite + simulators green.

### Core-engine crashes/corruption (live server)
- [x] fail-storm panic (dead result buffers behind live asserts)
- [x] uncapped promote panic
- [x] fetch-push send_buf overflow + payload_buf OOB (byte-budget claim)
- [x] bulk-move stale-queue claim corruption
- [x] deferred-recv stack buffer overflow
- [x] prefetch window leak on fail/skipped-ack (worker starvation)
- [x] HTTP enqueue/ack/fail not waking RPC-subscribed workers
- [x] heartbeat lease theft (worker-ownership guard)
- [x] retry-backoff u64 overflow
- [x] purge count-trigger unwired + uncapped purge stall

### Raft integration correctness (raft_*.zig, not yet wired into main)
- [x] applyReady applies all committed entries (conf_change no longer panics FSM)
- [x] re-check step-down before applying commits (no false durability ack)
- [x] validate inbound messages before step() (no crash on malformed frame)
- [x] bound entries-count allocation in raft_codec
- [x] recoverable tick errors no longer panic the co-located server

### Security
- [x] constant-time password/cookie compare
- [x] admin-role gate on backup/restore/cluster-join (RouteAction.admin_read)
- [x] webhook SSRF guard (loopback + link-local/IMDS)
- [x] RPC auth: MSG_AUTH handshake + per-role enforcement (all 6 SDKs updated)
- [x] cluster-port auth: HMAC challenge-response, --cluster-secret

### Feature
- [x] cron scheduler: cron_expr.zig parser + UTC next-fire + maintenance firing

---

## Phase 1 — talon integrity (the durability floor)

Needed so "a node can die and we keep the data" is actually true. Contained in
`talon.zig`. **First step: repoint corvo's talon dep from the pinned GitHub tag
to a local path (`.path = "../talon"`), or bump the tag — local talon edits do
NOT reach corvo today.**

- [ ] **Copy-on-write pages** — modified pages get new page ids (never overwrite
      a page the committed meta references); the meta flip is the atomic commit.
      talon already has dual-slot CRC meta + correct fsync ordering
      (`syncDataAndVlog` → meta write → `syncMeta`); in-place overwrites are the
      only thing defeating it. COW also fixes the dead freelist / unbounded growth.
- [ ] **Per-page checksums** verified on read (only meta is CRC'd today).
- [ ] **Dual-meta recovery**: on open, validate newest meta's pages via checksums;
      fall back to the previous good meta if bad. Never silently re-init/wipe.
- [ ] **2-transaction freelist retention** so the fallback snapshot's pages aren't
      recycled (enables COW + reclaims space).
- [ ] Crash-injection sim: kill at random syscall points + torn-write injection,
      assert recovery yields a valid tree (sim does NO crash testing today).

### Opt-in (config, default off when clustered)
- [ ] `sync = none | fdatasync | fsync` (ordering already implemented, just gated).
- [ ] macOS `F_FULLFSYNC` inside the sync path (plain fsync doesn't flush drive cache).
- [ ] group commit / batched fsync when sync is on.

### Localized talon bugs (fix alongside)
- [ ] iterator returns empty value for vlog entries (kv_read reads via iter.value())
- [ ] raft snapshot > 256 KiB panics (ValueLog.append assert) — chunk or lift cap
- [ ] decodePage slot_start underflow computed before assert
- [ ] no pread fallback → mmap failure silently yields empty DB
- [ ] batch pool unsynchronized (matters once raft thread + pipeline share a DB)

---

## Phase 2 — zig-raft consensus safety

Latent because raft isn't wired in, but must be fixed before it is. **Add the
missing VOPR invariants first** so the fixes are provable.

- [ ] **VOPR gaps** (do first): no liveness/progress invariant; no committed-entry
      durability ledger; DoubleVote (I7) declared but unchecked; no commit-index
      monotonicity or Leader Completeness check; fault classes are siloed
      (snapshots never combined with dup/partition).
- [ ] **C1 (critical)** derivePeers doesn't remap match/next_index on peer slot
      shift → commit without quorum → acked-write loss on membership change.
- [ ] **C2 (critical)** follower commit uses min(leaderCommit, lastIndex) instead
      of last-new-entry; next_index rewind unclamped → stale divergent commit.
- [ ] M1 ReadIndex has no current-term-committed barrier + no no-op on becomeLeader
      → stale linearizable read after leader change.
- [ ] M2 single-node cluster never advances commit_index.
- [ ] M3 RequestVote from a non-member → assert(stable.len>0) panic.
- [ ] M4 truncating the only conf_change entry leaves a stale config + stuck
      conf_change_pending.
- [ ] M5 stale AE overlapping a compacted log → step() returns a hard error.

---

## Phase 3 — wire raft into the binary

Turn the tested scaffolding into live clustering.

- [ ] `--raft` config path in main.zig (peer specs WITH uuids, cluster_id,
      cluster-port → RaftHost.create/registerPeer/start).
- [ ] pipeline integration: replace repl_hook/last_acked_seq with proposeAsync +
      token polling; defer client responses until the token is final.
- [ ] `raft_net` peer auth (async handshake — the live PBR transport is done; the
      io_uring raft transport still accepts any peer).
- [ ] migration: `raft_migrate` must move pre-existing KV data into the log or a
      snapshot (today joining followers silently diverge).
- [ ] snapshot/compaction trigger policy (log is never compacted → unbounded growth;
      OplogFsm.snapshot() is currently dead code).
- [ ] entry-size vs codec-frame cap (64×64KiB > 2MiB → replication livelock).
- [ ] ProposeToken safe-abandon (UAF/leak on timeout/disconnect).
- [ ] leadership-gated reads / ReadIndex use (raft_gate is codec-only today) +
      MSG_NOT_LEADER emission + SDK redial.

---

## Phase 4 — core-engine majors (live server)

- [ ] M3 io_uring user_data carries no generation → stale CQE hits a reused slot
      (cross-connection frame injection at high churn).
- [ ] M4 second queueSend while a send is in flight resends from offset 0.
- [ ] M2 batch enqueue partial-commit on error + total_jobs drift.
- [ ] M6 max_waiting_conns=4096 vs 20k target → 4097th subscriber panics
      (Pipeline is heap-allocated, so growing the arrays is stack-safe — verify).
- [ ] M5 frame backpressure permanently starves a pipelining connection.
- [ ] M8 sync-repl fetch released on the previous batch's ack.
- [ ] M10 indexer silently drops effects past 8192/tick (counter + read-index drift).
- [ ] M11 clear-queue + enqueue same tick re-applies stale counter deltas.
- [ ] M12 maintenance scans O(total) every second on the pipeline thread
      (promote/expire should break not continue; reclaim walks all active).
- [ ] M13 rate-limited fetch does an O(rate_limit) scan per fetch op.
- [ ] minors: reclaim/expire death fire no webhook; max_retries==0 semantics;
      duplicate batch id panic; unique-lock expiry lag; bulk move to nonexistent
      queue strands jobs; hot-path per-op heap allocs; drainCoalescing busy-spin.

---

## Deferred / decisions

- [D] Cron timezones — scheduler is UTC-only; the `timezone` field is ignored.
      Needs the IANA tz database. Separate effort.
- [D] "Leader fsyncs, followers don't" as a middle-ground durability default.
- [D] TLS on cluster + webhook transports (HMAC auth stops injection but the
      wire is still cleartext).
