#!/usr/bin/env bash
# bench-zig-cluster.sh — start a 3-node Zig PBR cluster, run RPC benchmark
#
# Usage:
#   ./bench-zig-cluster.sh                  # defaults: 100k jobs, c8, batch 128
#   ./bench-zig-cluster.sh --jobs 200000    # override bench flags

set -euo pipefail

RPC1=${RPC1:-9878}
RPC2=${RPC2:-9879}
RPC3=${RPC3:-9880}
PBR1=${PBR1:-9001}
PBR2=${PBR2:-9002}
PBR3=${PBR3:-9003}
HTTP1=${HTTP1:-8081}
HTTP2=${HTTP2:-8082}
HTTP3=${HTTP3:-8083}

DATA1=$(mktemp -d /tmp/corvo-zig-n1-XXXXXX)
DATA2=$(mktemp -d /tmp/corvo-zig-n2-XXXXXX)
DATA3=$(mktemp -d /tmp/corvo-zig-n3-XXXXXX)

ZIG_BIN="./zig-out/bin/corvo"
BENCH_BIN="./zig-out/bin/bench-rpc"

PIDS=()
cleanup() {
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$DATA1" "$DATA2" "$DATA3"
}
trap cleanup EXIT

# Build
echo "Building Zig server + bench..."
zig build -Doptimize=ReleaseFast 2>&1

if [[ ! -f "$ZIG_BIN" ]]; then
    echo "Error: $ZIG_BIN not found"
    exit 1
fi

# Default bench flags
BENCH_FLAGS=(--jobs 100000 --concurrency 8 --batch 128)
if [[ $# -gt 0 ]]; then
    BENCH_FLAGS=("$@")
fi

# Node 1
PEERS1="node-2@127.0.0.1:$PBR2,node-3@127.0.0.1:$PBR3"
echo "Starting node-1 (rpc=$RPC1, pbr=$PBR1)..."
"$ZIG_BIN" \
    --node-id node-1 --peers "$PEERS1" --pbr-port "$PBR1" \
    --port "$HTTP1" --rpc-port "$RPC1" \
    --data-dir "$DATA1" --no-mirror \
    &>"$DATA1/server.log" &
PIDS+=($!)

# Node 2
PEERS2="node-1@127.0.0.1:$PBR1,node-3@127.0.0.1:$PBR3"
echo "Starting node-2 (rpc=$RPC2, pbr=$PBR2)..."
"$ZIG_BIN" \
    --node-id node-2 --peers "$PEERS2" --pbr-port "$PBR2" \
    --port "$HTTP2" --rpc-port "$RPC2" \
    --data-dir "$DATA2" --no-mirror \
    &>"$DATA2/server.log" &
PIDS+=($!)

# Node 3
PEERS3="node-1@127.0.0.1:$PBR1,node-2@127.0.0.1:$PBR2"
echo "Starting node-3 (rpc=$RPC3, pbr=$PBR3)..."
"$ZIG_BIN" \
    --node-id node-3 --peers "$PEERS3" --pbr-port "$PBR3" \
    --port "$HTTP3" --rpc-port "$RPC3" \
    --data-dir "$DATA3" --no-mirror \
    &>"$DATA3/server.log" &
PIDS+=($!)

# Wait for servers to start (check RPC ports)
echo -n "Waiting for servers..."
for i in $(seq 1 50); do
    all_up=true
    for rpc_port in $RPC1 $RPC2 $RPC3; do
        if ! nc -z 127.0.0.1 "$rpc_port" 2>/dev/null; then
            all_up=false
            break
        fi
    done
    if $all_up; then
        echo " ready"
        break
    fi
    # Check processes still alive
    for pid in "${PIDS[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo " FAILED (pid $pid died)"
            for dir in "$DATA1" "$DATA2" "$DATA3"; do
                echo "--- $dir/server.log ---"
                cat "$dir/server.log" 2>/dev/null || true
            done
            exit 1
        fi
    done
    sleep 0.2
done

# Wait for leader election
echo "Waiting for leader election..."
sleep 5  # Election timeout is 3s, give some extra time

# Detect which node is leader by checking logs
LEADER_PORT=""
for i in 1 2 3; do
    dir_var="DATA$i"
    rpc_var="RPC$i"
    if grep -q "this node is the leader" "${!dir_var}/server.log" 2>/dev/null; then
        LEADER_PORT="${!rpc_var}"
        echo "Leader: node-$i (rpc port $LEADER_PORT)"
        break
    fi
done

if [[ -z "$LEADER_PORT" ]]; then
    echo "WARNING: Could not detect leader from logs, using node-1 (port $RPC1)"
    echo "--- Node 1 log ---"
    tail -10 "$DATA1/server.log"
    echo "--- Node 2 log ---"
    tail -10 "$DATA2/server.log"
    echo "--- Node 3 log ---"
    tail -10 "$DATA3/server.log"
    LEADER_PORT=$RPC1
fi

echo ""
echo "=== Corvo Zig 3-Node Cluster Benchmark ==="
echo "Bench flags: ${BENCH_FLAGS[*]}"
echo "Server: 127.0.0.1:$LEADER_PORT"
echo ""

# Run benchmark against leader
"$BENCH_BIN" --server "127.0.0.1:$LEADER_PORT" "${BENCH_FLAGS[@]}"

echo ""
echo "Server logs:"
echo "  Node 1: $DATA1/server.log"
echo "  Node 2: $DATA2/server.log"
echo "  Node 3: $DATA3/server.log"
