#!/usr/bin/env bash
set -euo pipefail

repo="/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-4/worktree"
deps="/tmp/fdb-harness-bootstrap-test/root"
test_binary="$repo/tests/mock_tests/tests"
test_source="$repo/tests/mock_tests/fdborch/fdborch_vxlan_ut.cpp"
test_filter="VxlanFdbOrchTest.MC4RR2TraceIsBlockedBySaiReferenceGuard"

if [[ ! -e "$deps/usr/lib/x86_64-linux-gnu/libsaivs.so" ]]; then
    echo "ERROR: extracted SONiC virtual-SAI dependencies are missing" >&2
    exit 2
fi

export LD_LIBRARY_PATH="$deps/usr/lib/x86_64-linux-gnu:$deps/usr/lib:/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="$deps/usr/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export FDB_SWSS_SHARE_DIR="$deps/usr/share/swss"
coverage_dir="$(mktemp -d /tmp/mc4-gcov.XXXXXX)"
trap 'rm -rf -- "$coverage_dir"' EXIT
export GCOV_PREFIX="$coverage_dir"
export GCOV_PREFIX_STRIP=5

echo "PRECHECK: source_sha=$(git -C "$repo" rev-parse HEAD), virtual_sai=$deps/usr/lib/x86_64-linux-gnu/libsaivs.so"

if [[ ! -f "$repo/tests/mock_tests/Makefile" ]]; then
    echo "BUILD: configuring SONiC's native mock-test harness"
    (
        cd "$repo"
        timeout 5m ./autogen.sh
        timeout 5m ./configure \
            --with-extra-inc="$deps/usr/include" \
            --with-extra-lib="$deps/usr/lib/x86_64-linux-gnu" \
            --with-extra-usr-lib="$deps/usr/lib"
    )
fi

if [[ ! -x "$test_binary" || "$test_source" -nt "$test_binary" ]]; then
    echo "BUILD: compiling SONiC's mock-test binary with the MC-4 harness"
    timeout 20m make -C "$repo/tests/mock_tests" -j8 -s \
        CXXFLAGS="-g -O0 -Wno-error=conversion" tests
fi

echo "RUN: $test_binary --gtest_filter=$test_filter"
set +e
output="$(cd "$repo/tests/mock_tests" && timeout 5m ./tests --gtest_color=no --gtest_filter="$test_filter" 2>&1)"
test_status=$?
set -e
printf '%s\n' "$output"
if [[ $test_status -ne 0 ]]; then
    echo "ERROR: test process exited with status $test_status" >&2
    exit "$test_status"
fi

grep -Fq "MC4 RR2 TRACE State2: learned_fdb_present=yes, bridge_port_present=yes" <<<"$output"
grep -Fq "MC4 RR2 TRACE State5: flush_status=failed, flush_calls=2, fdb_present=yes, bridge_port_present=yes" <<<"$output"
grep -Eq "MC4 IMPLEMENTATION MASK: remove_status=-17, expected_OBJECT_IN_USE=-17, bridge_port_present=yes, fdb_present=yes, admin_state=down" <<<"$output"
grep -Fq "MC4 CALLER: vlan_member_task_erased=yes, retry_scheduled=no" <<<"$output"
grep -Fq "MC4 MODEL MISMATCH: RR003_State6_bridge_port_present=no is unreachable" <<<"$output"
grep -Fq "[  PASSED  ] 1 test." <<<"$output"

echo "RESULT: PASS - RR003 State 6 is blocked by the real SAI reference guard; the caller still erases its task"
