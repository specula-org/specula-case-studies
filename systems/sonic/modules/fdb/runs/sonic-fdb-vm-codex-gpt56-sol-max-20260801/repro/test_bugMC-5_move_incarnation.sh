#!/usr/bin/env bash
set -euo pipefail

source_dir=${FDB_MC5_SOURCE_DIR:-/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-5/worktree}
deps_prefix=${FDB_MC5_DEPS_PREFIX:-/tmp/fdb-harness-bootstrap-test/root}
expected_revision=4f3dda156e52ed7647b1dbf900d54d87efaea455
test_binary="$source_dir/tests/mock_tests/tests"

actual_revision=$(git -C "$source_dir" rev-parse HEAD)
if [[ "$actual_revision" != "$expected_revision" ]]; then
    echo "MC5_PRECHECK wrong_source_revision=$actual_revision expected=$expected_revision" >&2
    exit 2
fi
if [[ ! -x "$test_binary" ]]; then
    echo "MC5_PRECHECK missing_test_binary=$test_binary" >&2
    exit 2
fi
if [[ ! -f "$deps_prefix/usr/lib/x86_64-linux-gnu/libswsscommon.so" ]]; then
    echo "MC5_PRECHECK missing_dependency_prefix=$deps_prefix" >&2
    exit 2
fi

gcov_dir=$(mktemp -d /tmp/mc5-gcov.XXXXXX)
cleanup()
{
    if [[ -d "$gcov_dir" ]]; then
        find "$gcov_dir" -depth -delete
    fi
}
trap cleanup EXIT

library_path="$deps_prefix/usr/lib/x86_64-linux-gnu:$deps_prefix/usr/lib:/usr/local/lib"

echo "MC5_PRECHECK source_revision=$actual_revision"
echo "MC5_PRECHECK test_binary=$test_binary"
cd "$source_dir/tests/mock_tests"
timeout 120 env \
    GCOV_PREFIX="$gcov_dir" \
    GCOV_PREFIX_STRIP=4 \
    FDB_SWSS_SHARE_DIR="$deps_prefix/usr/share/swss" \
    LD_LIBRARY_PATH="$library_path" \
    "$test_binary" --gtest_color=no \
    --gtest_filter=VxlanFdbOrchTest.MC5MoveRepairFailureOwnership
