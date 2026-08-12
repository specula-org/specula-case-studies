#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/scenario_common.sh"

run_backend_success
begin_fast_reboot
export SPECULA_COMPONENT_MODE=reconciled
unset SPECULA_TIMEOUT_AS_READY_COMPONENT || true
run_finalizer
