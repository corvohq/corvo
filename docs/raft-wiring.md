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
and root swap assume one thread), so corvo serializes ALL cross-thread access
— writes and reads — with a single exclusive `std.Thread.Mutex` owned by
main (`db_lock`). An RwLock with shared read access was considered; the
exclusive mutex is the stronger, simpler guarantee and is what ships.

The raft thread holds `db_lock` for the DB-touching span of each tick: the
inbox drain (accepting a proposal can flush the batcher into raft storage —
a talon write — when a batch crosses the per-entry cap) and `runtime.tick`
(log appends, FSM applies, snapshot work). Peer socket I/O (`peer_net.tick`:
reconnects, HMAC handshakes, frame encode/decode) never touches the DB and
runs BEFORE the lock is taken, so pipeline client traffic does not stall
behind peer-socket work.

Lock ordering: the raft thread nests `db_lock` → inbox mutex (drainInbox
runs under the DB lock). The pipeline takes the inbox mutex only inside
`proposeAsync`, which never touches `db_lock`, and it releases `db_lock`
before calling proposeAsync — no cycle, no deadlock.

Single-node mode (no `--node-id`) has no raft thread; the lock is null and the
direct-commit path is byte-for-byte today's.

## Write path (leader)

Unchanged hot path, new gating tail:

1. executeBatch decodes + applies frames into one kv.Batch with mutation
   recording on, and commits **locally, immediately** (exactly like PBR sync).
   This preserves read-your-writes across in-flight batches and prepare-slot
   pipelining.
2. After commit: `proposeAsync(mut_list)` → `*ProposeToken` stored in the
   batch's PrepareSlot (replacing `ack_seq`). The host deep-copies the
   mutations into a bounded inbox (back-pressure: `InboxFull`); the raft
   thread feeds the inbox to the batcher in order. The batcher copies the
   encoded bytes into its own pending buffer at enqueue, so proposal data
   never dangles into freed pipeline/host memory.
3. The batcher coalesces the tick's proposals into ONE raft entry, capped at
   `max_entry_bytes`. When a tick's proposals overflow the cap (two 256 KiB
   enqueues, say), the batch is flushed mid-drain as one entry and the next
   proposal starts a new batch — overflow is legal load, never a failed
   token. If the raft log's in-flight window is full, the proposal simply
   stays queued in the inbox (token pending) and is retried next tick.
4. Each flushed entry records the (index, term) it was proposed under.
   Responses for the batch stay deferred in the slot until the token flips:
   - `committed` → flush sends, release token. Fires only when the committed
     entry at that index carries the SAME term we proposed — the raft
     runtime applies entries to the FSM *before* firing completions, so a
     committed token implies the write is durable on a quorum.
   - `failed` → **fail-stop panic**. Fires only for genuinely terminal
     outcomes: not-leader at propose, oversize proposal, or divergence —
     see below.
   - `pending` → keep waiting (FIFO, same as the ack_seq design).

Maintenance batches (promote/reclaim/expire/purge/cron/webhook records) flow
through the same record → commit → propose path and only run on the leader.

### FSM skip on the leader

The leader already applied its own mutations at execute time. When those
entries commit, the FSM must NOT re-apply them: with up to 4 batches in
flight, re-applying entry k would transiently overwrite keys that in-flight
batch k+1 already wrote locally — a real read-back corruption, not just
staleness. The batcher knows which (index, term) pairs were self-proposed;
applyReady bumps `r:applied` for an exact match without touching data. The
term must match: a committed entry at a self-proposed index but a DIFFERENT
term is another leader's entry with different data and takes the full apply
path. Crash between local commit and the applied bump is safe: restart
re-applies the entry's mutations over identical state (set/delete are
idempotent assignments).

### Divergence = fail-stop

A token fails after local commit only when the write is genuinely gone from
the cluster's history. Losing leadership with the proposal in flight is NOT
by itself a failure: the entry is in our log and possibly replicated, so its
completion is deferred until the log decides —

- the entry commits carrying our original (index, term) — possibly under a
  NEW leader that inherited it — → token `committed`, truthful ack;
- a higher-term leader truncates/overwrites it (detected by the post-step
  log reconciliation, by the (index, term) check at commit time, or by an
  incoming InstallSnapshot that replaces state wholesale) → token `failed`;
- an unflushed pending proposal at step-down (locally committed, never in
  any log) → token `failed`.

On `failed` the node's local state contains writes the cluster discarded.
There is no entry-wise rollback for mutation replication, so the node panics
with an explicit "state diverged from cluster: wipe the data dir and rejoin"
message. Same fail-stop philosophy as kv.zig's PageCorrupt handling. Rare:
requires leader change with in-flight batches AND the cluster actually
discarding the write.

Raft-thread storage failures fail-stop too: a follower whose log append
fails in step() or a leader that cannot append to its own log panics with
context instead of silently dropping replication. Other tick errors are
counted (`tick_errors`) and logged rate-limited.

## Leadership state machine (pipeline)

- `follower` — write frames answered with MSG_NOT_LEADER (RPC) or 503
  (HTTP). The MSG_NOT_LEADER frame format (raft_gate) supports a leader id +
  client addr hint, but corvo currently always sends an EMPTY hint — clients
  redial through their seed list to find the leader. Reads served from talon
  under the DB mutex (stale-ok, documented). No maintenance, no warmup, no
  handler in-memory state maintenance.
- `acquiring` — entered when `host.isLeader()` flips true. Propose an empty
  barrier entry; when its token commits, all prior terms' entries are applied
  locally → `handler.rebuildState(&stores)` under the DB mutex → `leading`.
  If the barrier fails (lost leadership immediately), back to `follower` —
  no local commits happened, so no divergence.
- `leading` — normal write path above. When `host.isLeader()` flips false:
  if prepare slots are empty, drop cleanly to `follower`; if slots are in
  flight their tokens stay pending until the log decides (see divergence
  above) — committed truthfully, or failed → fail-stop.

Peer addressing: peer specs carry the *client* address; the raft transport
binds on client port + 1000 (same convention PBR used for its cluster port).

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

**Shared-config hash check.** `--cluster-id` only separates clusters; it does
not guarantee two voters agree on the *behavioral* params that drive replicated
state. `config.zig`'s `clusterHash()` folds those shared params — payload/queue/
job/tag limits, `persist-completed`, and every maintenance interval (promote,
reclaim, unique, rate-limit, expire, purge interval/retention/threshold, workers
interval/timeout, cron) — into one FNV-1a value. Each node carries its hash into
the raft_net peer handshake, where it rides *inside* the HMAC'd material
(`nonce ++ config_hash`), so it authenticates the peer AND can't be rewritten by
a man-in-the-middle. A peer whose hash differs is refused (`config_hash_rejects`,
logged once as "config hash mismatch — shared cluster params differ") and stays
refused on every reconnect, so it can never replicate or win an election. This
matters because maintenance runs only on the leader and ships through the log: a
node misconfigured with, say, `purge-retention=1h` that won a failover election
would delete terminal jobs cluster-wide through the raft log — unrecoverable
replicated data loss. The handshake — and with it the config check — runs on
every peer connection, secret or not: the misconfiguration it catches is an
operator typo, which needs no attacker. With an empty secret the HMAC provides
no authentication but still transports and binds the config hash; setting
`--cluster-secret` upgrades the same tags to peer authentication. Node-local
settings (bind, ports, data dir, conn caps, node id, peers, the secret itself)
are excluded — they legitimately differ per node.

## Known limitations (accepted for Phase 3)

- Commit latency is bounded below by the raft thread's 5ms tick interval;
  event-driven proposal wakeups are a follow-up perf item. Single-node
  deployments are unaffected.
- Snapshot serialization holds the DB mutex and runs O(db) on the raft
  thread (blocks heartbeats for very large stores) — documented at the
  trigger site.
- Follower reads are stale-by-design; ReadIndex-gated linearizable reads are
  wired only where leadership gating is required.
- Membership change (add/remove voter at runtime) is not exposed; clusters
  are static.
