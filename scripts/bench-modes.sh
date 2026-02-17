#!/usr/bin/env bash
#
# Benchmark Corvo across different server configurations.
#
# Usage:
#   ./scripts/bench-modes.sh                  # all modes
#   ./scripts/bench-modes.sh bolt badger      # specific stores only
#   SHARDS="1 4" ./scripts/bench-modes.sh     # override shard counts
#   JOBS=50000 ./scripts/bench-modes.sh       # override bench jobs
#   DURABLE=true ./scripts/bench-modes.sh     # test durable mode
#   PRESET=cluster ./scripts/bench-modes.sh   # 3-node cluster (auto NODES=3)
#   NODES=5 PRESET=cluster ./scripts/bench-modes.sh  # 5-node cluster
#
# Results are saved to bench-results/ and a comparison table is printed at the end.

set -euo pipefail

BINARY="bin/corvo"
RESULTS_DIR="bench-results"
BIND="${BIND:-:8080}"
SERVER_URL="${SERVER_URL:-http://localhost:8080}"
DATA_BASE="${DATA_BASE:-/tmp/corvo-bench}"
STORES="${STORES:-bolt badger pebble}"
SHARDS="${SHARDS:-1}"
PRESET="${PRESET:-single-node}"

# Default NODES based on preset: cluster gets 3 nodes, others get 1.
if [ -z "${NODES:-}" ]; then
    if [ "$PRESET" = "cluster" ]; then
        NODES=3
    else
        NODES=1
    fi
fi
JOBS="${JOBS:-}"
PROTOCOL="${PROTOCOL:-rpc}"
DURABLE="${DURABLE:-false}"
CONCURRENCY="${CONCURRENCY:-}"
WORKERS="${WORKERS:-}"
WORKER_QUEUES="${WORKER_QUEUES:-}"
FETCH_POLL_INTERVAL="${FETCH_POLL_INTERVAL:-}"
IDLE_FETCH_SLEEP="${IDLE_FETCH_SLEEP:-}"
STREAM_MAX_FPS="${STREAM_MAX_FPS:-}"
SQLITE_MIRROR="${SQLITE_MIRROR:-false}"
APPLY_MULTI_MODE="${APPLY_MULTI_MODE:-}"
COMBINED="${COMBINED:-}"

SERVER_PID=""
NODE_PIDS=()

mkdir -p "$RESULTS_DIR"

cleanup() {
    # Kill leader (SERVER_PID) first so it stops trying to reach followers.
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$SERVER_PID" 2>/dev/null || true
    fi
    SERVER_PID=""
    # Then kill followers.
    if [ ${#NODE_PIDS[@]} -gt 0 ]; then
        for pid in "${NODE_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done
        for pid in "${NODE_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                for _ in $(seq 1 20); do
                    kill -0 "$pid" 2>/dev/null || break
                    sleep 0.1
                done
                kill -9 "$pid" 2>/dev/null || true
            fi
        done
    fi
    NODE_PIDS=()
}

trap cleanup EXIT INT TERM

# Build once.
echo "==> Building corvo..."
CGO_ENABLED=1 go build -o "$BINARY" ./cmd/corvo

wait_healthy() {
    local url="$1"
    for _ in $(seq 1 30); do
        if curl -sf "${url}/healthz" > /dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    echo "ERROR: server did not become healthy at $url" >&2
    return 1
}

run_one() {
    local store="$1"
    local shards="$2"
    local label="${store}-s${shards}-${PROTOCOL}"
    if [ "$NODES" -gt 1 ]; then
        label="${label}-n${NODES}"
    fi
    if [ "$DURABLE" = "true" ]; then
        label="${label}-durable"
    fi

    local data_dir="${DATA_BASE}/${label}"
    local save_path="${RESULTS_DIR}/${label}.json"

    echo ""
    echo "============================================================"
    echo "==> Benchmarking: store=$store shards=$shards nodes=$NODES durable=$DURABLE"
    echo "============================================================"

    # Clean data dir for a fresh run.
    rm -rf "$data_dir"
    mkdir -p "$data_dir"

    # Common server args (no bind/data-dir/node-id — those are per-node).
    local common_args=(
        server
        --raft-store "$store"
        --raft-shards "$shards"
        --log-level error
    )
    if [ "$DURABLE" = "true" ]; then
        common_args+=(--durable)
    fi
    if [ -n "$FETCH_POLL_INTERVAL" ]; then
        common_args+=(--fetch-poll-interval "$FETCH_POLL_INTERVAL")
    fi
    if [ -n "$IDLE_FETCH_SLEEP" ]; then
        common_args+=(--idle-fetch-sleep "$IDLE_FETCH_SLEEP")
    fi
    if [ -n "$STREAM_MAX_FPS" ]; then
        common_args+=(--stream-max-fps "$STREAM_MAX_FPS")
    fi
    if [ "$SQLITE_MIRROR" = "false" ]; then
        common_args+=(--sqlite-mirror=false)
    fi
    if [ -n "$APPLY_MULTI_MODE" ]; then
        common_args+=(--apply-multi-mode "$APPLY_MULTI_MODE")
    fi
    # High snapshot threshold to avoid snapshot storms during benchmarks.
    common_args+=(--snapshot-threshold 1000000)

    if [ "$NODES" -gt 1 ]; then
        echo "==> Starting ${NODES}-node cluster..."

        # Multi-raft sharding: each shard uses raft_base_port + shard_index,
        # so nodes must be spaced by at least $shards ports apart.
        local raft_stride=$shards
        if [ "$raft_stride" -lt 1 ]; then
            raft_stride=1
        fi

        # Start leader (node-1) first.
        local leader_dir="${data_dir}/node-1"
        local leader_raft_port=9000
        mkdir -p "$leader_dir"
        echo "==> Starting leader node-1 (:8080, raft :${leader_raft_port}+${raft_stride} ports)..."
        "$BINARY" "${common_args[@]}" \
            --node-id "node-1" \
            --data-dir "$leader_dir" \
            --bind ":8080" \
            --raft-bind ":${leader_raft_port}" \
            --bootstrap &
        SERVER_PID=$!

        if ! wait_healthy "http://localhost:8080"; then
            cleanup
            return 1
        fi
        echo "==> Leader ready (pid=$SERVER_PID)"

        # Start follower nodes that join the leader.
        for i in $(seq 2 "$NODES"); do
            local http_port=$((8080 + i - 1))
            local raft_port=$((9000 + (i - 1) * raft_stride))
            local follower_dir="${data_dir}/node-${i}"
            mkdir -p "$follower_dir"
            echo "==> Starting follower node-${i} (:${http_port}, raft :${raft_port}+${raft_stride} ports)..."
            "$BINARY" "${common_args[@]}" \
                --node-id "node-${i}" \
                --data-dir "$follower_dir" \
                --bind ":${http_port}" \
                --raft-bind ":${raft_port}" \
                --bootstrap=false \
                --join "http://localhost:8080" &
            NODE_PIDS+=($!)

            if ! wait_healthy "http://localhost:${http_port}"; then
                echo "WARNING: follower node-${i} did not become healthy" >&2
            fi
        done
        echo "==> Cluster ready: ${NODES} nodes"
    else
        # Single-node mode.
        "$BINARY" "${common_args[@]}" \
            --bind "$BIND" \
            --data-dir "$data_dir" &
        SERVER_PID=$!

        if ! wait_healthy "$SERVER_URL"; then
            cleanup
            return 1
        fi
    fi

    echo "==> Server ready (pid=$SERVER_PID), starting bench..."

    # Build bench args.
    local bench_args=(
        bench
        --server "$SERVER_URL"
        --preset "$PRESET"
        --protocol "$PROTOCOL"
        --save "$save_path"
    )
    if [ -n "$JOBS" ]; then
        bench_args+=(--jobs "$JOBS")
    fi
    if [ -n "$CONCURRENCY" ]; then
        bench_args+=(--concurrency "$CONCURRENCY")
    fi
    if [ -n "$WORKERS" ]; then
        bench_args+=(--workers "$WORKERS")
    fi
    if [ -n "$WORKER_QUEUES" ]; then
        bench_args+=(--worker-queues "$WORKER_QUEUES")
    fi
    if [ "$COMBINED" = "true" ]; then
        bench_args+=(--combined)
    fi

    "$BINARY" "${bench_args[@]}" || true

    # Stop server and wait for port release.
    cleanup
    sleep 1
}

# Run each combination.
for store in $STORES; do
    for shard_count in $SHARDS; do
        run_one "$store" "$shard_count"
    done
done

# Print comparison table.
echo ""
echo "============================================================"
echo "==> Summary"
echo "============================================================"
echo ""

results=("$RESULTS_DIR"/*.json)
if [ ${#results[@]} -lt 2 ]; then
    echo "Only one result — nothing to compare."
    echo "Results saved to $RESULTS_DIR/"
    exit 0
fi

echo "Legend:"
echo "  Config     bench run name: {store}-s{shards}-{protocol}"
echo "  Jobs       total jobs enqueued then processed"
echo "  Conc       parallel lifecycle streams (workers x concurrency)"
echo "  Enq ops/s  enqueue throughput (jobs/sec, fire-and-forget)"
echo "  Enq p99    99th percentile enqueue latency (client round-trip)"
echo "  Enq CV     enqueue coefficient of variation (stddev/mean; lower = more consistent)"
echo "  LC ops/s   lifecycle throughput (jobs/sec, each op = fetch + ack on serialized stream)"
echo "  LC p99     99th percentile lifecycle latency (fetch receipt to ack confirmation)"
echo "  LC CV      lifecycle coefficient of variation"
echo "  CB ops/s   combined throughput (jobs/sec, concurrent enqueue+fetch+ack)"
echo "  CB p99     combined e2e latency p99 (enqueue to ack)"
echo ""
printf "%-24s  %6s  %5s  %10s  %10s  %7s  %10s  %10s  %7s  %10s  %10s\n" "Config" "Jobs" "Conc" "Enq ops/s" "Enq p99" "Enq CV" "LC ops/s" "LC p99" "LC CV" "CB ops/s" "CB p99"
printf "%-24s  %6s  %5s  %10s  %10s  %7s  %10s  %10s  %7s  %10s  %10s\n" "------------------------" "------" "-----" "----------" "----------" "-------" "----------" "----------" "-------" "----------" "----------"

for f in "${results[@]}"; do
    name=$(basename "$f" .json)
    jobs=$(jq -r '.config.jobs // "-"' "$f" 2>/dev/null || echo "-")
    conc=$(jq -r '.config.concurrency // "-"' "$f" 2>/dev/null || echo "-")
    enq_ops=$(jq -r '.enqueue.ops_per_sec // 0 | floor' "$f" 2>/dev/null || echo "0")
    enq_p99=$(jq -r 'if .enqueue.p99_us then (.enqueue.p99_us / 1000 | . * 10 | floor / 10 | tostring + "ms") else "-" end' "$f" 2>/dev/null || echo "-")
    enq_cv=$(jq -r 'if .enqueue.cv_pct then (.enqueue.cv_pct * 10 | floor / 10 | tostring + "%") else "-" end' "$f" 2>/dev/null || echo "-")
    lc_ops=$(jq -r '.lifecycle.ops_per_sec // 0 | floor' "$f" 2>/dev/null || echo "0")
    lc_p99=$(jq -r 'if .lifecycle.p99_us then (.lifecycle.p99_us / 1000 | . * 10 | floor / 10 | tostring + "ms") else "-" end' "$f" 2>/dev/null || echo "-")
    lc_cv=$(jq -r 'if .lifecycle.cv_pct then (.lifecycle.cv_pct * 10 | floor / 10 | tostring + "%") else "-" end' "$f" 2>/dev/null || echo "-")
    cb_ops=$(jq -r '.combined.ops_per_sec // 0 | floor' "$f" 2>/dev/null || echo "0")
    cb_p99=$(jq -r 'if .combined.p99_us then (.combined.p99_us / 1000 | . * 10 | floor / 10 | tostring + "ms") else "-" end' "$f" 2>/dev/null || echo "-")
    printf "%-24s  %6s  %5s  %10s  %10s  %7s  %10s  %10s  %7s  %10s  %10s\n" "$name" "$jobs" "$conc" "$enq_ops" "$enq_p99" "$enq_cv" "$lc_ops" "$lc_p99" "$lc_cv" "$cb_ops" "$cb_p99"
done

echo ""
echo "Results saved to $RESULTS_DIR/"
