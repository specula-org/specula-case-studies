#!/bin/bash
# apply.sh — Apply instrumentation to the libgomp source tree.
# Run from the case study root directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/gcc"
LIBGOMP="$ARTIFACT/libgomp"

echo "=== Applying instrumentation ==="

# 1. Copy trace header into libgomp source tree.
cp "$SCRIPT_DIR/src/tla_trace.h" "$LIBGOMP/tla_trace.h"
echo "  Copied tla_trace.h"

# 2. Ensure support headers exist.
mkdir -p "$ARTIFACT/include"
if [ ! -f "$ARTIFACT/include/gomp-constants.h" ]; then
    echo "  ERROR: gomp-constants.h not found. Run the full build setup first."
    exit 1
fi

# 3. Ensure futex_waitv.h exists.
if [ ! -f "$LIBGOMP/config/linux/futex_waitv.h" ]; then
    echo "  Creating minimal futex_waitv.h"
    cat > "$LIBGOMP/config/linux/futex_waitv.h" << 'FUTEX_EOF'
#ifndef FUTEX_WAITV_H
#define FUTEX_WAITV_H
#include <linux/futex.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <errno.h>
static inline void
futex_waitv (int *addr1, int val1, int *addr2, int val2)
{
  syscall (SYS_futex, addr1, FUTEX_WAIT_PRIVATE, val1, NULL);
}
#endif
FUTEX_EOF
fi

echo "  Instrumentation applied."
