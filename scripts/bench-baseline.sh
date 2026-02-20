#!/usr/bin/env bash
#
# Structured baseline benchmark runner for Corvo.
#
# Runs predefined benchmark suites with structured naming, saving JSON results
# tied to the current git commit. Use bench-compare.sh to diff two result sets.
#
# Usage:
#   ./scripts/bench-baseline.sh              # standard mode (default, ~10-15 min)
#   ./scripts/bench-baseline.sh quick        # smoke test (~2 min)
#   ./scripts/bench-baseline.sh full         # comprehensive (~45-60 min)
#   CI=true ./scripts/bench-baseline.sh standard  # GitHub Actions safe (~3 min)
#   STORE=pebble ./scripts/bench-baseline.sh      # override store backend
#
# Result directory: bench-results/{git-commit-short}/
# Result naming:    {mode}-{combined|separate}-w{workers}-c{concurrency}-s{shards}-n{nodes}-j{jobs}.json

set -euo pipefail

MODE="${1:-standard}"
BINARY="bin/corvo"
STORE="${STORE:-badger}"
BIND_BASE=8080
DATA_BASE="${DATA_BASE:-/tmp/corvo-bench-baseline}"
SERVER_URL="http://localhost:${BIND_BASE}"

COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
RESULTS_DIR="bench-results/${COMMIT}"

SERVER_PID=""
NODE_PIDS=()

# ── CI overlay ──────────────────────────────────────────────────────────────

CI_JOBS_CAP=10000
CI_WORKERS_CAP=8
CI_CONCURRENCY_CAP=16
CI_SERVER_EXTRA_FLAGS=()

is_ci() {
    [ "${CI:-}" = "true" ]
}

ci_cap() {
    local val="$1" cap="$2"
    if is_ci && [ "$val" -gt "$cap" ]; then
        echo "$cap"
    else
        echo "$val"
    fi
}

if is_ci; then
    CI_SERVER_EXTRA_FLAGS=(--raft-max-pending 4096 --stream-max-inflight 512)
fi

# ── Mode definitions ────────────────────────────────────────────────────────

generate_runs() {
    local mode="$1"

    case "$mode" in
        quick)
            local jobs; jobs=$(ci_cap 10000 "$CI_JOBS_CAP")
            local workers; workers=$(ci_cap 2 "$CI_WORKERS_CAP")
            local conc; conc=$(ci_cap 8 "$CI_CONCURRENCY_CAP")
            echo "combined $jobs $workers $conc 1 1"
            echo "separate $jobs $workers $conc 1 1"
            ;;
        standard)
            local base_jobs=50000
            local shards_list="1 3"
            local workers_list="2 8 32"
            local conc_list="8 32"

            if is_ci; then
                base_jobs=$CI_JOBS_CAP
                shards_list="1"
                workers_list="2 8"
                conc_list="8 16"
            fi

            for shards in $shards_list; do
                for workers in $workers_list; do
                    workers=$(ci_cap "$workers" "$CI_WORKERS_CAP")
                    for conc in $conc_list; do
                        conc=$(ci_cap "$conc" "$CI_CONCURRENCY_CAP")
                        local jobs; jobs=$(ci_cap "$base_jobs" "$CI_JOBS_CAP")
                        echo "combined $jobs $workers $conc $shards 1"
                        echo "separate $jobs $workers $conc $shards 1"
                    done
                done
            done
            ;;
        full)
            local jobs_list="100000 500000"
            local workers_list="2 8 32 128"
            local conc_list="8 32"
            local shards_list="1 2 3"
            local nodes_list="1 3"

            if is_ci; then
                jobs_list="$CI_JOBS_CAP"
                workers_list="2 8"
                conc_list="8 16"
                shards_list="1"
                nodes_list="1"
            fi

            for nodes in $nodes_list; do
                for shards in $shards_list; do
                    for jobs in $jobs_list; do
                        jobs=$(ci_cap "$jobs" "$CI_JOBS_CAP")
                        for workers in $workers_list; do
                            workers=$(ci_cap "$workers" "$CI_WORKERS_CAP")
                            for conc in $conc_list; do
                                conc=$(ci_cap "$conc" "$CI_CONCURRENCY_CAP")
                                # Skip redundant: high workers + low concurrency on small job counts.
                                if [ "$workers" -ge 128 ] && [ "$conc" -le 8 ] && [ "$jobs" -le 100000 ]; then
                                    continue
                                fi
                                # Skip multi-node + high shards (diminishing returns for bench).
                                if [ "$nodes" -gt 1 ] && [ "$shards" -gt 1 ] && [ "$workers" -ge 128 ]; then
                                    continue
                                fi
                                echo "combined $jobs $workers $conc $shards $nodes"
                                echo "separate $jobs $workers $conc $shards $nodes"
                            done
                        done
                    done
                done
            done
            ;;
        *)
            echo "ERROR: unknown mode '$mode' (expected quick, standard, or full)" >&2
            exit 1
            ;;
    esac
}

# ── Helpers ─────────────────────────────────────────────────────────────────

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$SERVER_PID" 2>/dev/null || true
    fi
    SERVER_PID=""
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

start_server() {
    local shards="$1"
    local nodes="$2"
    local data_dir="${DATA_BASE}/run-$$"

    rm -rf "$data_dir"
    mkdir -p "$data_dir"

    local common_args=(
        server
        --raft-store "$STORE"
        --raft-shards "$shards"
        --log-level error
        --snapshot-threshold 1000000
        --idle-fetch-sleep 10ms
    )
    if [ ${#CI_SERVER_EXTRA_FLAGS[@]} -gt 0 ]; then
        common_args+=("${CI_SERVER_EXTRA_FLAGS[@]}")
    fi

    if [ "$nodes" -gt 1 ]; then
        local raft_stride=$shards
        [ "$raft_stride" -lt 1 ] && raft_stride=1

        local leader_dir="${data_dir}/node-1"
        mkdir -p "$leader_dir"
        "$BINARY" "${common_args[@]}" \
            --node-id "node-1" \
            --data-dir "$leader_dir" \
            --bind ":${BIND_BASE}" \
            --raft-bind ":9000" \
            --bootstrap &
        SERVER_PID=$!

        if ! wait_healthy "$SERVER_URL"; then
            cleanup
            return 1
        fi

        for i in $(seq 2 "$nodes"); do
            local http_port=$((BIND_BASE + i - 1))
            local raft_port=$((9000 + (i - 1) * raft_stride))
            local follower_dir="${data_dir}/node-${i}"
            mkdir -p "$follower_dir"
            "$BINARY" "${common_args[@]}" \
                --node-id "node-${i}" \
                --data-dir "$follower_dir" \
                --bind ":${http_port}" \
                --raft-bind ":${raft_port}" \
                --bootstrap=false \
                --join "$SERVER_URL" &
            NODE_PIDS+=($!)

            if ! wait_healthy "http://localhost:${http_port}"; then
                echo "WARNING: follower node-${i} did not become healthy" >&2
            fi
        done
    else
        "$BINARY" "${common_args[@]}" \
            --bind ":${BIND_BASE}" \
            --data-dir "$data_dir" &
        SERVER_PID=$!

        if ! wait_healthy "$SERVER_URL"; then
            cleanup
            return 1
        fi
    fi
}

stop_server() {
    cleanup
    sleep 1
}

# ── Main ────────────────────────────────────────────────────────────────────

echo "==> Corvo Baseline Benchmark"
echo "    mode:   $MODE"
echo "    store:  $STORE"
echo "    commit: $COMMIT"
if is_ci; then
    echo "    CI:     true (capped: jobs=${CI_JOBS_CAP}, workers=${CI_WORKERS_CAP}, conc=${CI_CONCURRENCY_CAP})"
fi
echo "    output: $RESULTS_DIR/"
echo ""

# Build once.
echo "==> Building corvo..."
GOWORK=off go build -o "$BINARY" ./cmd/corvo

mkdir -p "$RESULTS_DIR"

# Deduplicate runs (CI capping can produce duplicates).
RUNS=$(generate_runs "$MODE" | sort -u)
TOTAL=$(echo "$RUNS" | wc -l | tr -d ' ')
CURRENT=0

echo "==> ${TOTAL} benchmark runs planned"
echo ""

# Track last server config to avoid unnecessary restarts.
LAST_SHARDS=""
LAST_NODES=""

while IFS=' ' read -r bench_type jobs workers conc shards nodes; do
    CURRENT=$((CURRENT + 1))
    echo "==> Run ${CURRENT}/${TOTAL}"

    # Reuse running server if config matches.
    if [ "$shards" != "$LAST_SHARDS" ] || [ "$nodes" != "$LAST_NODES" ]; then
        if [ -n "$SERVER_PID" ]; then
            stop_server
        fi
        LAST_SHARDS=""
        LAST_NODES=""
    fi

    local_label="${MODE}-${bench_type}-w${workers}-c${conc}-s${shards}-n${nodes}-j${jobs}"
    save_path="${RESULTS_DIR}/${local_label}.json"

    echo "--- ${local_label} ---"

    if [ -z "$SERVER_PID" ] || ! kill -0 "$SERVER_PID" 2>/dev/null; then
        start_server "$shards" "$nodes"
        LAST_SHARDS="$shards"
        LAST_NODES="$nodes"
    fi

    bench_args=(
        bench
        --server "$SERVER_URL"
        --protocol rpc
        --jobs "$jobs"
        --workers "$workers"
        --concurrency "$conc"
        --save "$save_path"
    )
    if [ "$bench_type" = "combined" ]; then
        bench_args+=(--combined)
    fi

    "$BINARY" "${bench_args[@]}" || true

done <<< "$RUNS"

stop_server

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo "==> Baseline Complete"
echo "============================================================"
echo ""

results=("$RESULTS_DIR"/*.json)
if [ ${#results[@]} -eq 0 ]; then
    echo "No results produced."
    exit 1
fi

# -- Combined (steady-state): enqueue + fetch + ack interleaved --
echo "Combined (steady-state)"
echo "  Enqueue and lifecycle run concurrently. CV measures latency consistency under load."
echo ""
printf "%-60s  %10s  %10s  %10s  %8s\n" "Run" "ops/sec" "p99" "stddev" "CV%"
printf "%-60s  %10s  %10s  %10s  %8s\n" "------------------------------------------------------------" "----------" "----------" "----------" "--------"

has_combined=false
for f in "${results[@]}"; do
    name=$(basename "$f" .json)
    cb_ops=$(jq -r '.combined.ops_per_sec // 0 | floor' "$f" 2>/dev/null || echo "0")
    [ "$cb_ops" = "0" ] && continue
    has_combined=true
    cb_p99=$(jq -r 'if .combined.p99_us then (.combined.p99_us / 1000 | . * 10 | floor / 10 | tostring + "ms") else "-" end' "$f" 2>/dev/null || echo "-")
    cb_stddev=$(jq -r 'if .combined.stddev_us then (.combined.stddev_us / 1000 | . * 10 | floor / 10 | tostring + "ms") else "-" end' "$f" 2>/dev/null || echo "-")
    cb_cv=$(jq -r '.combined.cv_pct // 0 | . * 10 | floor / 10' "$f" 2>/dev/null || echo "-")
    printf "%-60s  %10s  %10s  %10s  %8s\n" "$name" "$cb_ops" "$cb_p99" "$cb_stddev" "$cb_cv"
done
if [ "$has_combined" = "false" ]; then
    echo "  (none)"
fi

# -- Separate (burst): enqueue first, then fetch + ack --
echo ""
echo "Separate (burst)"
echo "  Enqueue runs to completion, then lifecycle processes all jobs. Shows per-phase ceilings."
echo ""
printf "%-60s  %10s  %10s\n" "Run" "ops/sec" "p99"
printf "%-60s  %10s  %10s\n" "------------------------------------------------------------" "----------" "----------"

has_separate=false
for f in "${results[@]}"; do
    name=$(basename "$f" .json)
    cb_ops=$(jq -r '.combined.ops_per_sec // 0 | floor' "$f" 2>/dev/null || echo "0")
    [ "$cb_ops" != "0" ] && continue
    has_separate=true
    enq_ops=$(jq -r '.enqueue.ops_per_sec // 0 | floor' "$f" 2>/dev/null || echo "0")
    enq_p99=$(jq -r 'if .enqueue.p99_us then (.enqueue.p99_us / 1000 | . * 10 | floor / 10 | tostring + "ms") else "-" end' "$f" 2>/dev/null || echo "-")
    lc_ops=$(jq -r '.lifecycle.ops_per_sec // 0 | floor' "$f" 2>/dev/null || echo "0")
    lc_p99=$(jq -r 'if .lifecycle.p99_us then (.lifecycle.p99_us / 1000 | . * 10 | floor / 10 | tostring + "ms") else "-" end' "$f" 2>/dev/null || echo "-")
    printf "%-60s  %10s  %10s\n" "$name" "$lc_ops" "$lc_p99"
    printf "%-60s  %10s  %10s\n" "  enqueue" "$enq_ops" "$enq_p99"
done
if [ "$has_separate" = "false" ]; then
    echo "  (none)"
fi

echo ""
echo "Results saved to $RESULTS_DIR/"
echo "Compare with: ./scripts/bench-compare.sh $RESULTS_DIR <other-results-dir>"
