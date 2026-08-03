#!/usr/bin/env bash
set -euo pipefail

readonly REPO="/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-2/worktree"
readonly TEST_DIR="${REPO}/tests/mock_tests"
readonly TEST_BIN="${TEST_DIR}/tests"
readonly DEPS_ROOT="/tmp/fdb-harness-bootstrap-test/root/usr"
readonly DEPS_ARCH="${DEPS_ROOT}/lib/x86_64-linux-gnu"
readonly DEPS_USR="${DEPS_ROOT}/lib"
readonly SWSS_SHARE="${DEPS_ROOT}/share/swss"
readonly GCOV_DIR="/tmp/specula-mc2-gcov"

printf '%s\n' 'MC-2 ladder Level 0: unavailable (no live SONiC SAI/ASIC stack in this confirmation environment)'
printf '%s\n' 'MC-2 ladder Level 1: not triggerable here (timing alone cannot reorder callbacks without the live producer)'
printf '%s\n' 'MC-2 ladder Level 2: instantiate CE State 4 at the public FdbOrch handler boundary; deliver LEARN(gen2,same port), then delayed AGE(gen1)'

if [[ ! -f "${REPO}/Makefile" ]]; then
    cd "${REPO}"
    ./autogen.sh
    CPPFLAGS="-I${DEPS_ROOT}/include -I${DEPS_ROOT}/include/swss -I/usr/local/include/swss" \
    LDFLAGS="-L${DEPS_ARCH} -L${DEPS_USR} -L/usr/local/lib -Wl,-rpath,${DEPS_ARCH} -Wl,-rpath,${DEPS_USR} -Wl,-rpath,/usr/local/lib" \
    PKG_CONFIG_PATH="${DEPS_ARCH}/pkgconfig" \
        ./configure --with-extra-inc="${DEPS_ROOT}/include"
fi

make --silent -C "${TEST_DIR}" -j4 \
    CXXFLAGS='-g -O2 -Wno-error=conversion' tests

cd "${TEST_DIR}"
mkdir -p "${GCOV_DIR}"

FDB_SWSS_SHARE_DIR="${SWSS_SHARE}" \
GCOV_PREFIX="${GCOV_DIR}" \
GCOV_PREFIX_STRIP=4 \
LD_LIBRARY_PATH="${DEPS_ARCH}:${DEPS_USR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${TEST_BIN}" \
    --gtest_color=no \
    --gtest_filter='VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation'
