#!/usr/bin/env bash
# bench-zig.sh — start Zig server, benchmark with Go client
#
# Uses the Go `corvo bench` client against the Zig HTTP server.
# This gives an apples-to-apples comparison: same client, same protocol,
# same benchmark parameters — only the server differs.
#
# Usage:
#   ./bench-zig.sh                    # defaults: 100k jobs, c8, batch 64
#   ./bench-zig.sh --jobs 200000      # override bench flags
#
# Prerequisites:
#   - Zig server built: zig build -Doptimize=ReleaseFast
#   - Go bench client built: go build -o ./corvo ./cmd/corvo/

set -euo pipefail

PORT=${PORT:-9877}
DATA_DIR=$(mktemp -d /tmp/corvo-zig-bench-XXXXXX)
ZIG_BIN="./zig-out/bin/corvo"
GO_BIN="./corvo"

# Bench flags (passed to Go bench client)
BENCH_FLAGS=(
    --server "http://localhost:$PORT"
    --protocol http
    --concurrency 8
    --workers 1
    --jobs 100000
    --enqueue-batch-size 64
    --fetch-batch-size 64
    --ack-batch-size 64
)
if [[ $# -gt 0 ]]; then
    BENCH_FLAGS=("$@" --server "http://localhost:$PORT" --protocol http)
fi

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$DATA_DIR"
}
trap cleanup EXIT

# Build Zig server
echo "Building Zig server..."
zig build -Doptimize=ReleaseFast 2>&1

if [[ ! -f "$ZIG_BIN" ]]; then
    echo "Error: $ZIG_BIN not found. Check build output."
    exit 1
fi

# Build Go bench client if needed
if [[ ! -f "$GO_BIN" ]]; then
    echo "Building Go bench client..."
    go build -o "$GO_BIN" ./cmd/corvo/
fi

# Start Zig server
echo "Starting Zig server on :$PORT (data: $DATA_DIR)..."
"$ZIG_BIN" --port "$PORT" --data-dir "$DATA_DIR" --no-mirror &>"$DATA_DIR/server.log" &
SERVER_PID=$!

# Wait for server ready
echo -n "Waiting for server..."
for i in $(seq 1 50); do
    if curl -sf "http://localhost:$PORT/healthz" >/dev/null 2>&1; then
        echo " ready (pid=$SERVER_PID)"
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo " FAILED"
        echo "Server log:"
        cat "$DATA_DIR/server.log"
        exit 1
    fi
    sleep 0.1
done

if ! curl -sf "http://localhost:$PORT/healthz" >/dev/null 2>&1; then
    echo " TIMEOUT"
    echo "Server log:"
    cat "$DATA_DIR/server.log"
    exit 1
fi

echo ""
echo "=== Corvo Zig Benchmark ==="
echo "Bench flags: ${BENCH_FLAGS[*]}"
echo ""

# Run benchmark
"$GO_BIN" bench "${BENCH_FLAGS[@]}"

echo ""
echo "Server log: $DATA_DIR/server.log"
