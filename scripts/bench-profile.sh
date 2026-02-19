#!/usr/bin/env bash
#
# Profile a Corvo lifecycle benchmark with pprof.
#
# Starts a server, captures a CPU profile during the bench run,
# then prints top consumers and opens an interactive pprof session.
#
# Usage:
#   ./scripts/bench-profile.sh                  # defaults
#   JOBS=200000 WORKERS=32 ./scripts/bench-profile.sh
#   PROFILE_SECONDS=60 ./scripts/bench-profile.sh
#   PROFILE_TYPE=heap ./scripts/bench-profile.sh  # heap instead of cpu
#   PPROF_INTERACTIVE=0 ./scripts/bench-profile.sh  # skip interactive
#
# Environment variables:
#   JOBS              Total jobs (default: 100000)
#   WORKERS           Worker count (default: 32)
#   CONCURRENCY       Streams per worker (default: 2)
#   FETCH_BATCH       Fetch batch size (default: 64)
#   ACK_BATCH         Ack batch size (default: 64)
#   RAFT_STORE        Raft log backend (default: badger)
#   MULTI_MODE        Multi-apply mode (default: indexed)
#   BIND              Server bind address (default: :9090)
#   DATA_DIR          Server data directory (default: /tmp/corvo-bench-profile)
#   PROFILE_SECONDS   CPU profile duration (default: 30)
#   PROFILE_TYPE      Profile type: cpu, heap, goroutine, block, mutex (default: cpu)
#   PPROF_INTERACTIVE Open interactive pprof at the end (default: 1)
#   EXTRA_SERVER_ARGS Additional server flags
#   EXTRA_BENCH_ARGS  Additional bench flags

set -euo pipefail

BINARY="${BINARY:-bin/corvo}"
BIND="${BIND:-:9090}"
PORT="${BIND##*:}"
SERVER_URL="http://localhost:${PORT}"
DATA_DIR="${DATA_DIR:-/tmp/corvo-bench-profile}"
PROFILE_DIR="${PROFILE_DIR:-/tmp/corvo-profiles}"

JOBS="${JOBS:-100000}"
WORKERS="${WORKERS:-32}"
CONCURRENCY="${CONCURRENCY:-2}"
FETCH_BATCH="${FETCH_BATCH:-64}"
ACK_BATCH="${ACK_BATCH:-64}"
RAFT_STORE="${RAFT_STORE:-badger}"
MULTI_MODE="${MULTI_MODE:-indexed}"
PROFILE_SECONDS="${PROFILE_SECONDS:-30}"
PROFILE_TYPE="${PROFILE_TYPE:-cpu}"
PPROF_INTERACTIVE="${PPROF_INTERACTIVE:-1}"
EXTRA_SERVER_ARGS="${EXTRA_SERVER_ARGS:-}"
EXTRA_BENCH_ARGS="${EXTRA_BENCH_ARGS:-}"

mkdir -p "$PROFILE_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PROFILE_FILE="${PROFILE_DIR}/corvo-${PROFILE_TYPE}-${TIMESTAMP}.prof"

# --- Build ---
echo "=== Building ==="
go build -o "$BINARY" ./cmd/corvo

# --- Cleanup ---
cleanup() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Start server ---
echo "=== Starting server ==="
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"

$BINARY server \
    --bind "$BIND" \
    --data-dir "$DATA_DIR" \
    --apply-multi-mode "$MULTI_MODE" \
    --raft-store "$RAFT_STORE" \
    --stream-max-inflight 16000 \
    --stream-max-open 20000 \
    --stream-max-fps 50000 \
    --idle-fetch-sleep 10ms \
    --fetch-poll-interval 10ms \
    --rate-limit-enabled=false \
    $EXTRA_SERVER_ARGS \
    >/dev/null 2>&1 &
SERVER_PID=$!

echo "  PID: $SERVER_PID"
echo "  Waiting for server..."
for i in $(seq 1 30); do
    if curl -sf "${SERVER_URL}/healthz" >/dev/null 2>&1; then
        echo "  Server ready."
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "  ERROR: Server exited unexpectedly."
        exit 1
    fi
    sleep 0.5
done

# --- Start profile capture ---
echo ""
echo "=== Capturing ${PROFILE_TYPE} profile (${PROFILE_SECONDS}s) ==="
if [[ "$PROFILE_TYPE" == "cpu" ]]; then
    curl -sf "${SERVER_URL}/debug/pprof/profile?seconds=${PROFILE_SECONDS}" -o "$PROFILE_FILE" &
    PROFILE_PID=$!
    sleep 2  # let profiler start before bench
elif [[ "$PROFILE_TYPE" == "heap" ]]; then
    # Heap profile is a snapshot — capture after bench
    PROFILE_PID=""
elif [[ "$PROFILE_TYPE" == "goroutine" ]]; then
    PROFILE_PID=""
elif [[ "$PROFILE_TYPE" == "block" ]]; then
    PROFILE_PID=""
elif [[ "$PROFILE_TYPE" == "mutex" ]]; then
    PROFILE_PID=""
else
    echo "Unknown profile type: $PROFILE_TYPE"
    exit 1
fi

# --- Run bench ---
echo ""
echo "=== Running benchmark ==="
echo "  jobs=$JOBS workers=$WORKERS concurrency=$CONCURRENCY"
echo "  fetch-batch=$FETCH_BATCH ack-batch=$ACK_BATCH"
echo "  raft-store=$RAFT_STORE multi-mode=$MULTI_MODE"
echo ""

$BINARY bench \
    --server "$SERVER_URL" \
    --jobs "$JOBS" \
    --workers "$WORKERS" \
    --concurrency "$CONCURRENCY" \
    --worker-queues \
    --fetch-batch-size "$FETCH_BATCH" \
    --ack-batch-size "$ACK_BATCH" \
    $EXTRA_BENCH_ARGS

# --- Capture non-CPU profiles after bench ---
if [[ "$PROFILE_TYPE" != "cpu" ]]; then
    echo ""
    echo "=== Capturing ${PROFILE_TYPE} profile snapshot ==="
    curl -sf "${SERVER_URL}/debug/pprof/${PROFILE_TYPE}" -o "$PROFILE_FILE"
    echo "  Saved to $PROFILE_FILE"
fi

# --- Wait for CPU profile to finish ---
if [[ -n "${PROFILE_PID:-}" ]]; then
    echo ""
    echo "=== Waiting for CPU profile to finish ==="
    wait "$PROFILE_PID" || true
fi

echo ""
echo "=== Profile saved: $PROFILE_FILE ==="
echo ""

# --- Analyze ---
echo "=== Top 30 CPU consumers ==="
go tool pprof -top 30 "$PROFILE_FILE" 2>/dev/null || true

echo ""
echo "=== Corvo-specific functions ==="
go tool pprof -top -nodecount=20 -focus='corvo' "$PROFILE_FILE" 2>/dev/null || true

echo ""
echo "=== Pebble functions ==="
go tool pprof -top -nodecount=15 -focus='pebble' "$PROFILE_FILE" 2>/dev/null || true

# --- Interactive ---
if [[ "$PPROF_INTERACTIVE" == "1" ]]; then
    echo ""
    echo "=== Opening interactive pprof (type 'web' for flamegraph, 'top' for top, 'quit' to exit) ==="
    go tool pprof "$PROFILE_FILE"
fi
