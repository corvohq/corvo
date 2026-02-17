#!/usr/bin/env bash
#
# Compare two sets of benchmark results from bench-baseline.sh.
#
# Usage:
#   ./scripts/bench-compare.sh bench-results/abc1234 bench-results/def5678
#   ./scripts/bench-compare.sh --before bench-results/abc1234 --after bench-results/def5678
#
# Matches results by filename (same parameters) and shows side-by-side metrics.
# Changes within +/-5% are marked as "~" (noise). Beyond that, "+" or "-" with percentage.

set -euo pipefail

# ── Parse arguments ─────────────────────────────────────────────────────────

BEFORE_DIR=""
AFTER_DIR=""
THRESHOLD=5

while [ $# -gt 0 ]; do
    case "$1" in
        --before)
            BEFORE_DIR="$2"; shift 2 ;;
        --after)
            AFTER_DIR="$2"; shift 2 ;;
        --threshold)
            THRESHOLD="$2"; shift 2 ;;
        *)
            if [ -z "$BEFORE_DIR" ]; then
                BEFORE_DIR="$1"
            elif [ -z "$AFTER_DIR" ]; then
                AFTER_DIR="$1"
            else
                echo "ERROR: unexpected argument '$1'" >&2
                exit 1
            fi
            shift ;;
    esac
done

if [ -z "$BEFORE_DIR" ] || [ -z "$AFTER_DIR" ]; then
    echo "Usage: $0 [--before] <before-dir> [--after] <after-dir>" >&2
    echo "       $0 bench-results/abc1234 bench-results/def5678" >&2
    exit 1
fi

if [ ! -d "$BEFORE_DIR" ]; then
    echo "ERROR: directory not found: $BEFORE_DIR" >&2
    exit 1
fi
if [ ! -d "$AFTER_DIR" ]; then
    echo "ERROR: directory not found: $AFTER_DIR" >&2
    exit 1
fi

# ── Color support ───────────────────────────────────────────────────────────

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    RESET=''
fi

# ── Comparison logic ────────────────────────────────────────────────────────

format_delta() {
    local before="$1" after="$2" higher_is_better="$3"
    if [ "$before" = "0" ] || [ "$before" = "" ]; then
        echo "n/a"
        return
    fi

    local pct
    pct=$(awk "BEGIN { printf \"%.1f\", ($after - $before) / $before * 100 }")
    local abs_pct
    abs_pct=$(awk "BEGIN { v = $pct; if (v < 0) v = -v; printf \"%.1f\", v }")

    # Within threshold = noise.
    local is_noise
    is_noise=$(awk "BEGIN { print ($abs_pct <= $THRESHOLD) ? 1 : 0 }")
    if [ "$is_noise" = "1" ]; then
        printf "${YELLOW}  ~%s%%${RESET}" "$pct"
        return
    fi

    # Determine if change is good or bad.
    local is_positive
    is_positive=$(awk "BEGIN { print ($pct > 0) ? 1 : 0 }")

    if [ "$higher_is_better" = "true" ]; then
        if [ "$is_positive" = "1" ]; then
            printf "${GREEN} +%s%%${RESET}" "$pct"
        else
            printf "${RED} %s%%${RESET}" "$pct"
        fi
    else
        if [ "$is_positive" = "1" ]; then
            printf "${RED} +%s%%${RESET}" "$pct"
        else
            printf "${GREEN} %s%%${RESET}" "$pct"
        fi
    fi
}

improved=0
regressed=0
unchanged=0

compare_metric() {
    local before="$1" after="$2" higher_is_better="$3"
    if [ "$before" = "0" ] || [ "$before" = "" ]; then
        return
    fi
    local pct
    pct=$(awk "BEGIN { v = ($after - $before) / $before * 100; if (v < 0) v = -v; printf \"%.1f\", v }")
    local is_noise
    is_noise=$(awk "BEGIN { print ($pct <= $THRESHOLD) ? 1 : 0 }")
    if [ "$is_noise" = "1" ]; then
        unchanged=$((unchanged + 1))
        return
    fi
    local is_positive
    is_positive=$(awk "BEGIN { print (($after - $before) > 0) ? 1 : 0 }")
    if [ "$higher_is_better" = "true" ]; then
        if [ "$is_positive" = "1" ]; then
            improved=$((improved + 1))
        else
            regressed=$((regressed + 1))
        fi
    else
        if [ "$is_positive" = "1" ]; then
            regressed=$((regressed + 1))
        else
            improved=$((improved + 1))
        fi
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

echo "Corvo Benchmark Comparison"
echo "  before: $BEFORE_DIR"
echo "  after:  $AFTER_DIR"
echo "  threshold: +/-${THRESHOLD}%"
echo ""

# Collect commit info from first result in each dir.
before_commit=$(jq -r '.commit // "?"' "$(ls "$BEFORE_DIR"/*.json 2>/dev/null | head -1)" 2>/dev/null || echo "?")
after_commit=$(jq -r '.commit // "?"' "$(ls "$AFTER_DIR"/*.json 2>/dev/null | head -1)" 2>/dev/null || echo "?")
echo "  before commit: $before_commit"
echo "  after commit:  $after_commit"
echo ""

# Header.
printf "%-55s  %10s  %10s  %12s\n" "Run" "Before" "After" "Delta"
printf "%-55s  %10s  %10s  %12s\n" "-------------------------------------------------------" "----------" "----------" "------------"

matched=0

for before_file in "$BEFORE_DIR"/*.json; do
    name=$(basename "$before_file")
    after_file="${AFTER_DIR}/${name}"

    if [ ! -f "$after_file" ]; then
        continue
    fi

    matched=$((matched + 1))
    label=$(basename "$name" .json)

    # Determine if this is a combined or separate run.
    cb_before=$(jq -r '.combined.ops_per_sec // 0' "$before_file" 2>/dev/null)
    cb_after=$(jq -r '.combined.ops_per_sec // 0' "$after_file" 2>/dev/null)

    if [ "$cb_before" != "0" ] && [ "$cb_after" != "0" ]; then
        # Combined: show ops/sec and p99.
        cb_p99_before=$(jq -r '.combined.p99_us // 0' "$before_file" 2>/dev/null)
        cb_p99_after=$(jq -r '.combined.p99_us // 0' "$after_file" 2>/dev/null)

        ops_before=$(printf "%.0f" "$cb_before")
        ops_after=$(printf "%.0f" "$cb_after")
        p99_before_ms=$(awk "BEGIN { printf \"%.1f\", $cb_p99_before / 1000 }")
        p99_after_ms=$(awk "BEGIN { printf \"%.1f\", $cb_p99_after / 1000 }")

        delta_ops=$(format_delta "$cb_before" "$cb_after" "true")
        delta_p99=$(format_delta "$cb_p99_before" "$cb_p99_after" "false")

        printf "%-55s  %10s  %10s  %b\n" "${label} ops/s" "$ops_before" "$ops_after" "$delta_ops"
        printf "%-55s  %10s  %10s  %b\n" "${label} p99" "${p99_before_ms}ms" "${p99_after_ms}ms" "$delta_p99"

        compare_metric "$cb_before" "$cb_after" "true"
        compare_metric "$cb_p99_before" "$cb_p99_after" "false"
    else
        # Separate: show enqueue and lifecycle.
        enq_before=$(jq -r '.enqueue.ops_per_sec // 0' "$before_file" 2>/dev/null)
        enq_after=$(jq -r '.enqueue.ops_per_sec // 0' "$after_file" 2>/dev/null)
        enq_p99_before=$(jq -r '.enqueue.p99_us // 0' "$before_file" 2>/dev/null)
        enq_p99_after=$(jq -r '.enqueue.p99_us // 0' "$after_file" 2>/dev/null)
        lc_before=$(jq -r '.lifecycle.ops_per_sec // 0' "$before_file" 2>/dev/null)
        lc_after=$(jq -r '.lifecycle.ops_per_sec // 0' "$after_file" 2>/dev/null)
        lc_p99_before=$(jq -r '.lifecycle.p99_us // 0' "$before_file" 2>/dev/null)
        lc_p99_after=$(jq -r '.lifecycle.p99_us // 0' "$after_file" 2>/dev/null)

        if [ "$enq_before" != "0" ] && [ "$enq_after" != "0" ]; then
            ops_b=$(printf "%.0f" "$enq_before")
            ops_a=$(printf "%.0f" "$enq_after")
            p99_b=$(awk "BEGIN { printf \"%.1f\", $enq_p99_before / 1000 }")
            p99_a=$(awk "BEGIN { printf \"%.1f\", $enq_p99_after / 1000 }")
            delta_ops=$(format_delta "$enq_before" "$enq_after" "true")
            delta_p99=$(format_delta "$enq_p99_before" "$enq_p99_after" "false")
            printf "%-55s  %10s  %10s  %b\n" "${label} enq ops/s" "$ops_b" "$ops_a" "$delta_ops"
            printf "%-55s  %10s  %10s  %b\n" "${label} enq p99" "${p99_b}ms" "${p99_a}ms" "$delta_p99"
            compare_metric "$enq_before" "$enq_after" "true"
            compare_metric "$enq_p99_before" "$enq_p99_after" "false"
        fi

        if [ "$lc_before" != "0" ] && [ "$lc_after" != "0" ]; then
            ops_b=$(printf "%.0f" "$lc_before")
            ops_a=$(printf "%.0f" "$lc_after")
            p99_b=$(awk "BEGIN { printf \"%.1f\", $lc_p99_before / 1000 }")
            p99_a=$(awk "BEGIN { printf \"%.1f\", $lc_p99_after / 1000 }")
            delta_ops=$(format_delta "$lc_before" "$lc_after" "true")
            delta_p99=$(format_delta "$lc_p99_before" "$lc_p99_after" "false")
            printf "%-55s  %10s  %10s  %b\n" "${label} lc ops/s" "$ops_b" "$ops_a" "$delta_ops"
            printf "%-55s  %10s  %10s  %b\n" "${label} lc p99" "${p99_b}ms" "${p99_a}ms" "$delta_p99"
            compare_metric "$lc_before" "$lc_after" "true"
            compare_metric "$lc_p99_before" "$lc_p99_after" "false"
        fi
    fi
done

echo ""

if [ "$matched" -eq 0 ]; then
    echo "No matching results found between the two directories."
    echo "Ensure both directories contain results with the same filenames."
    exit 1
fi

echo "------------------------------------------------------------"
printf "Summary: %d matched runs — " "$matched"
if [ "$improved" -gt 0 ]; then
    printf "${GREEN}%d improved${RESET}" "$improved"
else
    printf "0 improved"
fi
printf ", "
if [ "$regressed" -gt 0 ]; then
    printf "${RED}%d regressed${RESET}" "$regressed"
else
    printf "0 regressed"
fi
printf ", %d unchanged (within +/-%d%%)\n" "$unchanged" "$THRESHOLD"
