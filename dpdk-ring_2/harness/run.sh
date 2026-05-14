#!/usr/bin/env bash
# Build instrumented DPDK + run trace tests + merge per-thread traces.
#
# Run from anywhere — paths are absolute.  Idempotent (re-running starts
# from a clean tree).
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
SPECULA_OUT="$(cd "$HARNESS_DIR/.." && pwd)"
CASE_DIR="$(cd "$SPECULA_OUT/.." && pwd)"
DPDK_DIR="$CASE_DIR/artifact/dpdk"
TRACE_DIR="$SPECULA_OUT/traces"
NPROC="$(nproc)"

echo "================================================"
echo "  DPDK rte_ring (round 2) — Trace Harness"
echo "================================================"
echo "Case dir:    $CASE_DIR"
echo "DPDK dir:    $DPDK_DIR"
echo "Trace dir:   $TRACE_DIR"
echo "CPUs:        $NPROC"
echo

# ---- Step 1: Apply instrumentation ----
bash "$HARNESS_DIR/apply.sh"

# ---- Step 2: Build instrumented DPDK ----
echo
echo "=== Building instrumented DPDK ==="
cd "$DPDK_DIR"

rm -rf build install
meson setup build \
	--default-library=shared \
	-Ddisable_drivers='*' \
	-Dexamples='' \
	-Dtests=false \
	-Dc_args='-DDPDK_TLA_TRACE' \
	--warnlevel=0 \
	2>&1 | tail -5

echo "Building..."
ninja -C build -j"$NPROC" 2>&1 | tail -5

echo "Installing to local prefix..."
DESTDIR="$DPDK_DIR/install" ninja -C build install 2>&1 | tail -1

DPDK_INSTALL="$DPDK_DIR/install/usr/local"
DPDK_INCLUDE="$DPDK_INSTALL/include"
DPDK_LIB_DIR="$(find "$DPDK_INSTALL" -maxdepth 4 -name 'librte_ring.so' \
		-printf '%h\n' | head -1)"
if [ -z "${DPDK_LIB_DIR:-}" ]; then
	echo "ERROR: could not locate DPDK install lib dir" >&2
	exit 1
fi
echo "DPDK installed under $DPDK_INSTALL (libs in $DPDK_LIB_DIR)"

# ---- Step 3: Build test program ----
echo
echo "=== Building test program ==="
TEST_BIN="$HARNESS_DIR/test_ring_trace"

gcc -o "$TEST_BIN" \
	"$HARNESS_DIR/src/test_ring_trace.c" \
	-I"$DPDK_INCLUDE" \
	-I"$DPDK_DIR/lib/ring" \
	-include rte_config.h \
	-march=native \
	-DDPDK_TLA_TRACE \
	-L"$DPDK_LIB_DIR" \
	-Wl,-rpath,"$DPDK_LIB_DIR" \
	-Wl,--whole-archive \
	-lrte_ring -lrte_eal -lrte_telemetry -lrte_log \
	-lrte_kvargs -lrte_argparse -lrte_pmu \
	-Wl,--no-whole-archive \
	-lpthread -lnuma -lm -ldl

echo "Test binary: $TEST_BIN"

# ---- Step 4: Run test scenarios ----
echo
echo "=== Running trace tests ==="
mkdir -p "$TRACE_DIR"
rm -f "$TRACE_DIR"/*.ndjson "$TRACE_DIR"/*.json

export LD_LIBRARY_PATH="$DPDK_LIB_DIR"
export TRACE_DIR="$TRACE_DIR"

# Determine available CPUs (respecting cgroup/taskset limits).
AVAIL=$(python3 -c "
import os
parts = open('/proc/self/status').read().split('Cpus_allowed_list:\t')[1].split('\n')[0].split(',')
cpus = []
for p in parts:
    if '-' in p:
        a, b = p.split('-'); cpus.extend(range(int(a), int(b)+1))
    else:
        cpus.append(int(p))
print(','.join(str(c) for c in cpus[:3]))
")
echo "Using lcores: $AVAIL"
"$TEST_BIN" --no-huge --lcores="$AVAIL" --log-level=3 || echo "(test exited with non-zero; continuing)"

# ---- Step 5: Merge per-thread NDJSON files into per-tid JSON ----
echo
echo "=== Merging per-thread traces ==="
for prefix in trace_mt trace_hts trace_rts trace_soring trace_peek; do
	if ls "$TRACE_DIR/${prefix}-thread-"*.ndjson >/dev/null 2>&1; then
		python3 "$HARNESS_DIR/src/merge_traces.py" \
			"$TRACE_DIR/$prefix" \
			"$TRACE_DIR/$prefix.ndjson"
	else
		echo "  $prefix: no per-thread files (test may have skipped this scenario)"
	fi
done

# ---- Step 6: Report ----
echo
echo "=== Trace Results ==="
for prefix in trace_mt trace_hts trace_rts trace_soring trace_peek; do
	f="$TRACE_DIR/$prefix.ndjson"
	if [ -f "$f" ]; then
		python3 - "$f" <<'PYEOF'
import json, sys, collections
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception as e:
    print(f"  {p}: ERROR {e}")
    sys.exit(0)
if not isinstance(d, dict):
    print(f"  {p}: not an object")
    sys.exit(0)
total = sum(len(v) for v in d.values())
events = collections.Counter(ev.get("name") for tid in d for ev in d[tid])
top = ", ".join(f"{k}:{v}" for k, v in events.most_common(5))
import os
print(f"  {os.path.basename(p)}: {total} events / {len(d)} threads / "
      f"top: {top}")
PYEOF
	else
		echo "  $prefix.ndjson: (missing)"
	fi
done

echo
echo "================================================"
echo "  Done!  Merged traces in $TRACE_DIR/"
echo "================================================"
