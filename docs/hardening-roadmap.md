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

Milestone 1 DONE + verified on talon branch `hardening/cow-integrity` (COW +
checksums + recovery + crash-injection sim, ~900-line change, 2 commits).
**NOT yet integrated into corvo** — corvo still pins talon@v0.3.0 from GitHub, so
the COW work does not affect corvo's build until the re-pin below.

- [x] **Copy-on-write pages** — modified pages COW to fresh append-only pages;
      old root+pages stay intact for the previous meta. Fixed a no-op-commit bug
      (found via crash sim) that kept consecutive metas' roots distinct.
- [x] **Per-page checksums** (header 16→24, crc64) verified on read → `error.PageCorrupt`.
- [x] **Dual-meta recovery** (`recoverMeta`): validate newest root checksum, fall
      back to previous snapshot, else `error.Corrupt` — never re-inits over a file.
- [ ] **2-transaction freelist retention** — DEFERRED to Milestone 2. M1 leaks old
      pages (file grows, no regression vs today). Needed to reclaim space.
- [x] **Re-pin into corvo DONE + verified.** talon merged to master + tagged
      `v0.4.0` locally; corvo call sites handle `error.PageCorrupt` (kv.zig wrapper
      fail-stops → node crashes+resyncs; raft_storage maps to StorageError). Full
      corvo suite green against the COW talon. build.zig.zon pins talon by local
      path for now (like zig-raft). **FINALIZE before merge:** push talon
      `master` + `v0.4.0`, then swap build.zig.zon to
      `git+https://github.com/corvohq/talon.git#v0.4.0` + hash and re-verify.
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

## Phase 2 — zig-raft consensus safety — DONE + verified

Done on zig-raft branch `hardening/consensus-safety` (2 commits: safety fixes +
VOPR strengthening `7dd6111`, then a by-value-move regression fix `b086e6d`).
Verified: zig-raft `zig build test` + full VOPR green; the fixes provably caught
by the strengthened VOPR (temp reverts → I11 NoProgress / LogTooShort / C1 test
fail). A regression (broke corvo 3-node election via dangling `peer_storage`
slices after a by-value Node move) was caught in integration verification,
root-caused, and fixed by making the Node own its peer-id bytes.

- [x] **VOPR gaps**: added I10 durability ledger (Leader Completeness /
      commit-monotonicity), I11 progress/liveness, I7 DoubleVote; combined-fault
      seed groups (snapshot + dup/partition/delay); per-node snapshotting.
- [x] **C1** per-peer state now follows peer identity (snapshot-by-id-copy before
      config overwrite + restore-by-id). Node made relocatable (owns peer-id bytes).
- [x] **C2** follower commit clamps to prev_log_index+entries.len; next_index
      rewind clamps to match_index+1.
- [x] M1 ReadIndex current-term barrier (lazy no-op on read). M2 peerless commit.
      M3 non-member vote rejected. M4 config revert on truncate. M5 compacted-AE
      replies instead of erroring.
- Note: C1/M1/M3/M4 proven by unit tests (VOPR models neither membership changes
  nor client reads); C2 by unit tests (no random seed triggered the divergence).
  Adding membership/read modeling to the VOPR is future work.

---

## Phase 3 — wire raft into the binary — DONE (2026-07-07)

Raft is the live clustering stack; the legacy PBR stack (cluster.zig /
election.zig / replicator.zig / tcp_transport.zig / follower.zig /
cluster_sim.zig + the on-disk oplog Log) is REMOVED by maintainer decision.
Design + decisions: docs/raft-wiring.md. Verified: full suite 247/247 +
sim 3/3 green; live 3-node smoke (election, leader enqueue committed via
raft ~20ms, follower 503 not_leader, replication to followers, leader kill →
re-election → writes on new leader, old leader rejoin + catch-up).

- [x] cluster config path in main.zig: `--node-id`/`--peers id[:uuidhex]@host:port`
      (client addrs; raft transport = port+1000)/`--cluster-id` (required) →
      RaftHost.create/registerPeer/start. uuids derived from node id by default
      (deriveUuid), explicit hex override supported. `--sync-repl` and DNS
      discovery removed (raft is always-sync; membership is static).
- [x] pipeline integration: RaftIface vtable + proposeAsync token polling;
      prepare slots hold tokens; responses defer until every token commits;
      leader executes+commits locally, FSM skips self-proposed entries
      (locally_applied flag through batcher), failed-token-after-local-commit =
      divergence fail-stop; leadership state machine (follower → acquiring
      [barrier proposal + rebuildState] → leading); maintenance leader-only,
      through the same propose path; proposals split at frame boundaries
      (client-op atomicity) / mutation granularity (maintenance).
- [x] cross-thread DB safety: talon is single-threaded; a shared mutex
      serializes the pipeline's post-drain span against the raft thread's
      DB-touching tick span (docs/raft-wiring.md threading model).
- [x] `raft_net` peer auth: mutual HMAC-SHA256 challenge-response
      (--cluster-secret), constant-time verify, frames rejected until
      authenticated, auth_rejects counter.
- [~] migration: dropped by maintainer decision — pre-v1, no users, so no
      migration path; `raft_migrate` deleted and fresh clusters bootstrap from
      static `--peers` config (see docs/raft-wiring.md).
- [x] snapshot/compaction: threshold trigger (snapshot_threshold_entries,
      default 10k) → OplogFsm serialize → Node.compact → log prefix dropped;
      snapshot blob chunked in talon (128KiB chunks + manifest w/ xxhash) under
      the 256KiB vlog cap; restart recovery + follower InstallSnapshot catch-up
      tested. Also fixed: talon-iterator empty-value bug corrupting snapshots;
      dangling interior storage pointer in Runtime.
- [x] entry-size vs codec-frame cap: entries_per_msg lowered to 4 (Runtime
      forces it), per-entry byte cap derived from the frame cap (comptime
      livelock guard), batcher rejects oversize proposals (ProposalTooLarge),
      pipeline splits below the cap. Upstream (zig-raft) byte-aware
      AppendEntries assembly reported as the eventual fix for the ~512KiB
      per-op ceiling.
- [x] ProposeToken safe-abandon: refcounted (2 owners), release() valid at any
      time, host-side finish paths proven exactly-once.
- [x] leadership-gated writes + MSG_NOT_LEADER (RPC) / 503 not_leader (HTTP);
      barrier-on-acquisition = ReadIndex-equivalent for the rebuild; follower
      reads stale-by-design (documented). FOLLOW-UP: leader id/addr hint in the
      MSG_NOT_LEADER payload (empty today) + SDK redial in the 6 SDK repos.

### Phase 3 follow-ups (performance/operability, not correctness)
- [ ] event-driven raft-thread wakeup: commit latency is floored by the 5ms
      tick sleep (~20ms end-to-end today vs PBR sync sub-ms); an eventfd/futex
      wake on proposeAsync + pipelined drain would close most of the gap.
- [ ] leader identity published cross-thread (for NOT_LEADER hints +
      /cluster/status "leader" on followers + cluster events ring, which now
      returns empty).
- [ ] cluster metrics: term/commit-index gauges (epoch/lease gauges were
      PBR-only and removed).
- [ ] pipeline busy-drain while prepare slots pending (pre-existing
      drainCoalescing spin, more visible at raft latencies).

---

## Phase 4 — core-engine majors (live server)

Mostly DONE + verified on corvo `hardening/review-fixes` (`d375bd6`); corruption
fixes (M3/M4/M10/M11) read-verified, backed by the sim counter invariants across
40+ seeds; full suite 274/274 green.

- [x] M3 io_uring user_data now carries the ConnState generation; stale CQEs for a
      reused slot are dropped.
- [x] M4 queueSend extends send_len instead of resetting send_pos=0 while a send is
      in flight (no duplicate bytes).
- [x] M10 indexer flushes between ops at nearFull() + asserts (never silently drops);
      also fixed maintenance never flushing (dropped cron-enqueue indexes).
- [x] M11 clear-queue resets the cleared queue's pending/scheduled/retrying deltas.
- [x] M6 max_waiting_conns 4096→20480 + graceful subscription reject (stack-safe: heap).
- [x] M12 expire uses break (time-sorted keys); M13 rate-limit key collision fixed
      (monotonic lease_counter; count scans early-break).
- [~] M2 total_jobs drift fixed; the poison-batch partial-commit residual is NOT
      closed (needs a validation pre-pass rejected on hot-path perf grounds).
- [x] minors: reclaim/expire death fire the dead webhook; max_retries==0 → dead;
      duplicate batch id → error; bulk move validates the destination queue.
- [ ] NOT done (were out of the agent's scope): M5 frame-backpressure starvation,
      M8 sync-repl fetch released on previous batch's ack, unique-lock expiry lag,
      hot-path per-op heap allocs, drainCoalescing busy-spin.

---

## Deferred / decisions

- [D] Cron timezones — scheduler is UTC-only; the `timezone` field is ignored.
      Needs the IANA tz database. Separate effort.
- [D] "Leader fsyncs, followers don't" as a middle-ground durability default.
- [D] TLS on cluster + webhook transports (HMAC auth stops injection but the
      wire is still cleartext).
