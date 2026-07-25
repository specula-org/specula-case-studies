#!/bin/bash
# Bug #29 A/B Test: omp_fulfill_event deadlock from unshackled thread
#
# This script builds two versions of libgomp from GCC source (unpatched
# and patched with the one-line fix), then runs the same reproduction
# program against both to confirm:
#   - Unpatched: deterministic deadlock (exit 124)
#   - Patched:   completes successfully (exit 0)
#
# Prerequisites:
#   - Linux x86_64
#   - GCC with OpenMP support
#   - git (for sparse-checkout of GCC source)
#   - Internet access (to clone GCC repo)
#
# Usage:
#   chmod +x test_bug29.sh
#   ./test_bug29.sh
#
# The script is self-contained and clones the required GCC source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/bug29-test-$$"
GCC_TAG="releases/gcc-14.2.0"
RUNS=5
TIMEOUT=5

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
    echo ""
    echo "Work directory preserved at: $WORK_DIR"
}
trap cleanup EXIT

echo "========================================"
echo " Bug #29: omp_fulfill_event deadlock"
echo " A/B Controlled Test"
echo "========================================"
echo ""

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ── Step 1: Get GCC source ──────────────────────────────────────────
echo "[1/5] Cloning GCC $GCC_TAG (sparse: libgomp + include only)..."
if [ ! -d gcc-src ]; then
    git clone --depth 1 --branch "$GCC_TAG" --filter=blob:none --sparse \
        https://gcc.gnu.org/git/gcc.git gcc-src 2>&1 | tail -3
    cd gcc-src
    git sparse-checkout set libgomp include 2>&1
    cd ..
fi
echo "  Done."
echo ""

# ── Step 2: Build unpatched libgomp ─────────────────────────────────
echo "[2/5] Building unpatched libgomp..."
mkdir -p build-unpatched
cd build-unpatched
if [ ! -f .libs/libgomp.so.1.0.0 ]; then
    "$WORK_DIR/gcc-src/libgomp/configure" \
        --prefix="$WORK_DIR/install" --disable-multilib 2>&1 | tail -3
    # Build only the library (skip texinfo docs which may fail)
    make -j"$(nproc)" libgomp.la 2>&1 | tail -5
fi
UNPATCHED_LIB="$WORK_DIR/build-unpatched/.libs"
echo "  Built: $UNPATCHED_LIB/libgomp.so.1.0.0"
file "$UNPATCHED_LIB/libgomp.so.1.0.0" | grep -q "ELF" || { echo "ERROR: unpatched build failed"; exit 1; }
cd "$WORK_DIR"
echo ""

# ── Step 3: Apply patch and build patched libgomp ───────────────────
echo "[3/5] Applying fix and building patched libgomp..."

# Apply the one-line fix to the shared source tree
TASK_C="$WORK_DIR/gcc-src/libgomp/task.c"
if ! grep -q "gomp_team_barrier_set_task_pending" <(sed -n '2750,2770p' "$TASK_C"); then
    patch -p1 -d "$WORK_DIR/gcc-src" < "$SCRIPT_DIR/patches/bug29-fulfill-event-set-task-pending.patch"
    echo "  Patch applied."
else
    echo "  Patch already applied."
fi

mkdir -p build-patched
cd build-patched
if [ ! -f Makefile ]; then
    "$WORK_DIR/gcc-src/libgomp/configure" \
        --prefix="$WORK_DIR/install-patched" --disable-multilib 2>&1 | tail -3
fi
# Build (or rebuild task.o after patching) the library only
make -j"$(nproc)" libgomp.la 2>&1 | tail -5
PATCHED_LIB="$WORK_DIR/build-patched/.libs"
echo "  Built: $PATCHED_LIB/libgomp.so.1.0.0"
file "$PATCHED_LIB/libgomp.so.1.0.0" | grep -q "ELF" || { echo "ERROR: patched build failed"; exit 1; }
cd "$WORK_DIR"
echo ""

# ── Step 4: Compile reproduction program ────────────────────────────
echo "[4/5] Compiling reproduction program..."
gcc -fopenmp -O2 -lpthread -o detach_repro "$SCRIPT_DIR/detach_fulfill_deadlock.c"
echo "  Built: $WORK_DIR/detach_repro"
echo ""

# ── Step 5: Run A/B test ────────────────────────────────────────────
echo "[5/5] Running A/B test ($RUNS iterations each, ${TIMEOUT}s timeout)..."
echo ""

echo "  Source: identical GCC $GCC_TAG"
echo "  Compiler: $(gcc --version | head -1)"
echo "  Binary: same detach_repro for both tests"
echo "  Only difference: one-line fix in task.c"
echo ""

# Test A: Unpatched
echo -e "  ${YELLOW}Test A: Unpatched libgomp${NC}"
unpatched_pass=0
unpatched_fail=0
for i in $(seq 1 $RUNS); do
    if timeout $TIMEOUT env LD_LIBRARY_PATH="$UNPATCHED_LIB" ./detach_repro > /dev/null 2>&1; then
        echo -e "    Run $i: ${GREEN}exit 0 (no deadlock)${NC}"
        unpatched_pass=$((unpatched_pass + 1))
    else
        echo -e "    Run $i: ${RED}exit 124 (DEADLOCK)${NC}"
        unpatched_fail=$((unpatched_fail + 1))
    fi
done
echo ""

# Test B: Patched
echo -e "  ${YELLOW}Test B: Patched libgomp${NC}"
patched_pass=0
patched_fail=0
for i in $(seq 1 $RUNS); do
    if timeout $TIMEOUT env LD_LIBRARY_PATH="$PATCHED_LIB" ./detach_repro > /dev/null 2>&1; then
        echo -e "    Run $i: ${GREEN}exit 0 (no deadlock)${NC}"
        patched_pass=$((patched_pass + 1))
    else
        echo -e "    Run $i: ${RED}exit 124 (DEADLOCK)${NC}"
        patched_fail=$((patched_fail + 1))
    fi
done
echo ""

# ── Results ─────────────────────────────────────────────────────────
echo "========================================"
echo " Results"
echo "========================================"
echo ""
echo "  Unpatched: $unpatched_fail/$RUNS deadlocked, $unpatched_pass/$RUNS passed"
echo "  Patched:   $patched_fail/$RUNS deadlocked, $patched_pass/$RUNS passed"
echo ""

if [ "$unpatched_fail" -eq "$RUNS" ] && [ "$patched_pass" -eq "$RUNS" ]; then
    echo -e "  ${GREEN}BUG CONFIRMED: $RUNS/$RUNS deadlock without fix, $RUNS/$RUNS pass with fix.${NC}"
    exit 0
elif [ "$unpatched_fail" -gt 0 ] && [ "$patched_pass" -eq "$RUNS" ]; then
    echo -e "  ${YELLOW}BUG LIKELY CONFIRMED: $unpatched_fail/$RUNS deadlock without fix, $RUNS/$RUNS pass with fix.${NC}"
    exit 0
else
    echo -e "  ${RED}INCONCLUSIVE: Results do not match expected pattern.${NC}"
    exit 1
fi
