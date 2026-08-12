#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/scenario_common.sh"

run_backend_transport_failure
