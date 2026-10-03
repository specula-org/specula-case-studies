#!/usr/bin/env bash
set -euo pipefail

repo=${1:?Usage: run_all.sh /path/to/cass-operator}
expected_sha=704bf4c2e9a48e3d0381ddfaec6fb0346f0a164c
actual_sha=$(git -C "$repo" rev-parse HEAD)

if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "expected cass-operator $expected_sha, got $actual_sha" >&2
  exit 2
fi

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run_root=$(cd "$here/.." && pwd)
go_bin=${GO_BIN:-}
if [[ -z "$go_bin" ]]; then
  go_bin=$(command -v go || true)
fi
if [[ -z "$go_bin" && -x /usr/local/go/bin/go ]]; then
  go_bin=/usr/local/go/bin/go
fi
if [[ -z "$go_bin" ]]; then
  echo "Go toolchain not found" >&2
  exit 2
fi

declare -a installed=()
trace_dir="$repo/internal/speculatrace"
created_trace_dir=false

install_file() {
  local source=$1
  local destination=$2
  if [[ -e "$destination" ]]; then
    echo "refusing to overwrite existing file: $destination" >&2
    exit 2
  fi
  cp "$source" "$destination"
  installed+=("$destination")
}

cleanup() {
  local file
  for file in "${installed[@]}"; do
    rm -f -- "$file"
  done
  if [[ "$created_trace_dir" == true ]]; then
    rmdir -- "$trace_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ ! -d "$trace_dir" ]]; then
  mkdir -p "$trace_dir"
  created_trace_dir=true
fi

install_file "$run_root/harness/src/speculatrace/trace.go" "$trace_dir/trace.go"
install_file "$run_root/harness/src/pkg_reconciliation/specula_trace_scenarios_test.go" "$repo/pkg/reconciliation/zz_specula_case_harness_test.go"
install_file "$run_root/harness/src/internal_controllers_control/specula_trace_scenarios_test.go" "$repo/internal/controllers/control/zz_specula_case_harness_test.go"
install_file "$here/test_bugMC-1_cross_epoch_pvc_delete_test.go" "$repo/pkg/reconciliation/zz_specula_case_mc1_test.go"
install_file "$here/test_bugMC-2_premature_decommission_test.go" "$repo/pkg/reconciliation/zz_specula_case_mc2_test.go"
install_file "$here/test_bugMC-3_capacity_bypass_test.go" "$repo/pkg/reconciliation/zz_specula_case_mc3_test.go"
install_file "$here/test_bugMC-6_stuck_starting_after_lost_start.go" "$repo/pkg/reconciliation/zz_specula_case_mc6_test.go"
install_file "$here/test_bugMC-7_availability_floor_test.go" "$repo/pkg/reconciliation/zz_specula_case_mc7_test.go"
install_file "$here/test_bugMC-8_finalizer_deadlock_test.go" "$repo/pkg/reconciliation/zz_specula_case_mc8_test.go"

(cd "$repo" && timeout 15m "$go_bin" test ./pkg/reconciliation \
  -run '^(TestBugMC1|TestMC2_|TestBugMC3|TestBugMC6|TestSpeculaBugMC7|TestBugMC8_)' \
  -count=1 -v)

PATH="$(dirname "$go_bin"):$PATH" timeout 12m bash "$here/test_bugMC-5_double_submit.sh" "$repo"
