#!/bin/bash
set -euo pipefail

HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUTPUT_DIR=$(cd "$HARNESS_DIR/.." && pwd)
ARTIFACT_DIR=${SPECULA_ARTIFACT_DIR:-/users/Pial/targets/sonic-buildimage-warmreboot-high}

export PATH="$HARNESS_DIR/src/stubs:$PATH"
export PYTHONPATH="$HARNESS_DIR/src${PYTHONPATH:+:$PYTHONPATH}"
export SPECULA_TRACE_EMITTER="$HARNESS_DIR/src/trace_emit.py"
export SPECULA_TRACE_SH="$HARNESS_DIR/src/specula_trace.sh"
export SPECULA_TRACE_COMPONENTS=orchagent,xcvrd

run_backend_success()
{
    "$ARTIFACT_DIR/src/sonic-sysmgr/tests/tests" \
        --gtest_filter='TestWithStartupWarmbootEnabledState/RebootBEAutoStartTest.TestWarmRebootDbusToCompletion/0'
}

run_backend_transport_failure()
{
    "$ARTIFACT_DIR/src/sonic-sysmgr/tests/tests" \
        --gtest_filter='TestWithStartupWarmbootEnabledState/RebootBEAutoStartTest.TestWarmBootDbusError/0'
}

begin_fast_reboot()
{
    export SPECULA_LIBRARY_ONLY=1
    export NUM_ASIC=2
    export REBOOT_TYPE=warm-reboot
    # shellcheck disable=SC1090
    source "$ARTIFACT_DIR/src/sonic-utilities/scripts/fast-reboot"
    REBOOT_TYPE=warm-reboot
    ASIC_LIST=(0 1)
    specula_fast_reboot_begin
    local dev
    for dev in 0 1; do
        NETNS="asic$dev" enable_warm_restart
    done
    unset SPECULA_LIBRARY_ONLY
}

run_finalizer()
{
    export NUM_ASIC=2
    export PLATFORM=test-platform
    export ASIC_TYPE=vs
    bash "$ARTIFACT_DIR/files/image_config/warmboot-finalizer/finalize-warmboot.sh"
}
