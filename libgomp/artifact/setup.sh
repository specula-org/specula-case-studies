#!/bin/bash
# Setup script: clone GCC trunk and apply NVIDIA flat-barrier patch.
#
# Prerequisites: git, gcc build dependencies (see GCC docs)
#
# Usage:
#   cd artifact/
#   ./setup.sh            # clone + patch
#   ./setup.sh --build    # clone + patch + build libgomp

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GCC_DIR="$SCRIPT_DIR/gcc"
GCC_COMMIT="e0d9c5a23fff9002b6f971ee868bd05d7fa1e6ef"

if [ -d "$GCC_DIR" ] && [ -d "$GCC_DIR/.git" ]; then
    echo "GCC source tree already exists at $GCC_DIR"
    echo "Remove it first if you want a fresh clone."
    exit 0
fi

echo "=== Cloning GCC trunk (shallow) ==="
git clone --depth=1 https://gcc.gnu.org/git/gcc.git "$GCC_DIR"
cd "$GCC_DIR"

echo "=== Fetching target commit $GCC_COMMIT ==="
git fetch --depth=1 origin "$GCC_COMMIT"
git checkout "$GCC_COMMIT"

echo "=== Applying NVIDIA flat-barrier patch ==="
git apply "$SCRIPT_DIR/patches/nvidia_flat_barrier.patch"
echo "=== Patch applied successfully ==="

if [ "${1:-}" = "--build" ]; then
    echo "=== Building libgomp ==="
    BUILD_DIR="/tmp/libgomp-build"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    "$GCC_DIR/libgomp/configure" \
        --disable-multilib \
        CC=gcc CXX=g++ \
        CFLAGS="-g -O2" CXXFLAGS="-g -O2"
    make -j"$(nproc)" libgomp.la 2>&1 | tail -5
    echo "=== libgomp built at $BUILD_DIR/.libs/libgomp.so.1.0.0 ==="
fi
