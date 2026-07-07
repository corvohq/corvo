# Raft wiring design (Phase 3)

Decisions agreed with the maintainer 2026-07-07:

- **PBR is removed**, not kept as a fallback. Raft is the only cluster mode.
  cluster.zig / election.zig / replicator.zig / tcp_transport.zig / follower.zig /
  cluster_sim.zig are deleted along with the pipeline's repl_hook / last_acked_seq
  path.
- **No migration path.** Pre-v1, no users: a data dir created by the PBR build is
  not readable by a raft cluster. raft_migrate.zig is deleted. Fresh clusters
  bootstrap from static `--peers` config (zig-raft needs no synthetic conf_change
  for a static cluster).
- **zig-raft is tagged v0.1.0** and pinned like talon (pin swap pending the GitHub
  repo's creation).
- **Raft mode is always synchronous.** A raft commit *is* replication to a quorum,
  so `--sync-repl` is removed with PBR. An async ack mode (respond after local
  commit, before quorum) is possible later but out of scope.

## Threading model

Two threads share one talon DB: the pipeline thread (client traffic, local
commits) and the raft thread (log appends under `r:` keys, FSM applies,
snapshot serialization). talon is not internally synchronized (its batch pool
and root swap assume one thread), so corvo serializes cross-thread access with
a single `std.Thread.RwLock` owned by main:

- write lock: every batch (pipeline executeBatch/maintenance commits; raft
  storage appends + FSM apply batches), including newBatch/closeBatch (the
  batch pool is part of the unsynchronized surface).
- read lock: cross-thread reads (follower HTTP reads, leader snapshot
  serialization, raft log reads).

Lock ordering: the pipeline releases the write lock before calling
proposeAsync (which takes the host inbox mutex); the raft thread takes the
inbox mutex (drainInbox) and the DB lock at disjoint times. The two locks are
never nested across threads, so no deadlock.

Single-node mode (no `--node-id`) has no raft thread; the lock is null and the
direct-commit path is byte-for-byte today's.

## Write path (leader)

Unchanged hot path, new gating tail:

1. executeBatch decodes + applies frames into one kv.Batch with mutation
   recording on, and commits **locally, immediately** (exactly like PBR sync).
   This preserves read-your-writes across in-flight batches and prepare-slot
   pipelining.
2. After commit: `proposeAsync(mut_list)` → `*ProposeToken` stored in the
   batch's PrepareSlot (replacing `ack_seq`).
3. Responses for the batch stay deferred in the slot until the token flips:
   - `committed` → flush sends, release token. The raft runtime applies
     entries to the FSM *before* firing completions, so a committed token
     implies the write is durable on a quorum.
   - `failed` → **fail-stop panic**. See divergence below.
   - `pending` → keep waiting (FIFO, same as the ack_seq design).

Maintenance batches (promote/reclaim/expire/purge/cron/webhook records) flow
through the same record → commit → propose path and only run on the leader.

### FSM skip on the leader

The leader already applied its own mutations at execute time. When those
entries commit, the FSM must NOT re-apply them: with up to 4 batches in
flight, re-applying entry k would transiently overwrite keys that in-flight
batch k+1 already wrote locally — a real read-back corruption, not just
staleness. The batcher knows which indices were self-proposed; applyReady
bumps `r:applied` for those without touching data. Crash between local commit
and the applied bump is safe: restart re-applies the entry's mutations over
identical state (set/delete are idempotent assignments).

### Divergence = fail-stop

A token can only fail after local commit if leadership was lost with the
proposal in flight (the follower gate makes not-leader-at-propose unreachable
in steady state). The node's local state then contains writes the cluster may
never have committed. There is no entry-wise rollback for mutation
replication, so the node panics with an explicit "state diverged from
cluster: wipe the data dir and rejoin" message. Same fail-stop philosophy as
kv.zig's PageCorrupt handling. Rare: requires leader change with uncommitted
in-flight batches.

## Leadership state machine (pipeline)

- `follower` — write frames answered with MSG_NOT_LEADER (RPC, leader id +
  client addr hint via raft_gate) or 503 + leader hint (HTTP). Reads served
  from talon under the read lock (stale-ok, documented). No maintenance, no
  warmup, no handler in-memory state maintenance.
- `acquiring` — entered when `host.isLeader()` flips true. Propose an empty
  barrier entry; when its token commits, all prior terms' entries are applied
  locally → `handler.rebuildState(&stores)` under the write lock → `leading`.
  If the barrier fails (lost leadership immediately), back to `follower` —
  no local commits happened, so no divergence.
- `leading` — normal write path above. When `host.isLeader()` flips false:
  if prepare slots are empty, drop cleanly to `follower`; if slots are in
  flight their tokens will fail → fail-stop.

Client address hint: peer specs carry the *client* address; the raft
transport binds on client port + 1000 (same convention PBR used for its
cluster port).

## Config surface (main.zig)

- `--node-id <id>` — enables raft mode (as before it enabled PBR).
- `--peers id@host:port,...` — host:port is the peer's *client* address; raft
  transport is port+1000. An explicit per-peer uuid may be given as
  `id:uuidhex@host:port`; default is a uuid derived from the id (FNV-1a),
  which is fine for static clusters where a node id is never re-used for a
  different data dir.
- `--cluster-id <u64>` — required in raft mode, must match on all nodes
  (raft_runtime rejects cross-cluster traffic; 0 is reserved).
- `--cluster-secret` — HMAC peer auth on the raft transport (raft_net).
- Removed: `--sync-repl`, `--discover-dns-name` (DNS discovery + join was a
  PBR feature; raft membership change is future work).

## Known limitations (accepted for Phase 3)

- Commit latency is bounded below by the raft thread's 5ms tick interval;
  event-driven proposal wakeups are a follow-up perf item. Single-node
  deployments are unaffected.
- Snapshot serialization holds the DB read lock and runs O(db) on the raft
  thread (blocks heartbeats for very large stores) — documented at the
  trigger site.
- Follower reads are stale-by-design; ReadIndex-gated linearizable reads are
  wired only where leadership gating is required.
- Membership change (add/remove voter at runtime) is not exposed; clusters
  are static.
