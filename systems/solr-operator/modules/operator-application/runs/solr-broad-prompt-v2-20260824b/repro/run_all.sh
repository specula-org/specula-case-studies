#!/usr/bin/env bash
set -euo pipefail

source_repo=${1:?Usage: run_all.sh /path/to/solr-operator}
expected_sha=ed5c5c7d28a4c1189d19f581259e05385c0d4b20
actual_sha=$(git -C "$source_repo" rev-parse HEAD)

if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "expected solr-operator $expected_sha, got $actual_sha" >&2
  exit 2
fi

if [[ -n "$(git -C "$source_repo" status --porcelain --untracked-files=all)" ]]; then
  echo "source checkout must be clean" >&2
  exit 2
fi

go_bin=${GO_BIN:-$(command -v go || true)}
if [[ -z "$go_bin" && -x /usr/local/go/bin/go ]]; then
  go_bin=/usr/local/go/bin/go
fi
if [[ -z "$go_bin" ]]; then
  echo "Go toolchain not found" >&2
  exit 2
fi

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repro_tmp_dir=$(mktemp -d)
work_repo="$repro_tmp_dir/solr-operator"

cleanup() {
  chmod -R u+w "$repro_tmp_dir" 2>/dev/null || true
  rm -rf "$repro_tmp_dir"
}
trap cleanup EXIT

mkdir -p "$work_repo"
git -C "$source_repo" archive "$expected_sha" | tar -x -C "$work_repo"

run_go_program() {
  local program=$1
  (cd "$work_repo" && timeout 12m "$go_bin" run "$program")
}

run_go_program "$here/test_bugMC-1_replacenode_livelock.go"
SOURCE_REPO="$work_repo" GO_BIN="$go_bin" timeout 12m bash "$here/test_bugMC-1_managed_update_pull_only_survivor.sh"
run_go_program "$here/test_bugMC-3_backup_cohort.go"
run_go_program "$here/test_bugMC-4_async_cleanup_durability.go"
SOURCE_REPO="$work_repo" GO_BIN="$go_bin" timeout 12m bash "$here/test_bugMC-5_basic_auth_bootstrap_partial_create.sh"

envtest_assets=${KUBEBUILDER_ASSETS:-}
if [[ -z "$envtest_assets" ]]; then
  (cd "$work_repo" && \
    PATH="$(dirname "$go_bin"):$PATH" timeout 10m make setup-envtest && \
    PATH="$(dirname "$go_bin"):$PATH" timeout 10m make kubebuilder-assets)
  envtest_assets=$(find "$work_repo/bin/k8s" -mindepth 1 -maxdepth 1 -type d -print -quit)
fi
if [[ -z "$envtest_assets" || ! -x "$envtest_assets/kube-apiserver" || ! -x "$envtest_assets/etcd" ]]; then
  echo "envtest assets not found; set KUBEBUILDER_ASSETS" >&2
  exit 2
fi

mkdir -p "$work_repo/specula_cr5_repro"
cp "$here/test_bugCR-5_cross_namespace_exporter_test.go" "$work_repo/specula_cr5_repro/cr5_test.go"
(cd "$work_repo" && \
  SOURCE_REPO="$work_repo" \
  KUBEBUILDER_ASSETS="$envtest_assets" \
  timeout 12m "$go_bin" test ./specula_cr5_repro \
    -run '^TestCR5CrossNamespaceExporterStaysStale$' -count=1 -v)
