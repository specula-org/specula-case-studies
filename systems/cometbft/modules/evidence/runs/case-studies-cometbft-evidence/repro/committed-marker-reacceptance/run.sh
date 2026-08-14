#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/cometbft" >&2
  exit 2
fi

target_cometbft_root="$1"
test_src_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
evidence_pkg_dir="${target_cometbft_root}/evidence"
evidence_pkg="./evidence"
evidence_import_path="github.com/cometbft/cometbft/evidence"
go_bin="go"

if [[ ! -d "${evidence_pkg_dir}" && -d "${target_cometbft_root}/internal/evidence" ]]; then
  evidence_pkg_dir="${target_cometbft_root}/internal/evidence"
  evidence_pkg="./internal/evidence"
  evidence_import_path="github.com/cometbft/cometbft/internal/evidence"
fi

if [[ ! -d "${evidence_pkg_dir}" ]]; then
  echo "error: ${target_cometbft_root} does not look like a CometBFT checkout" >&2
  exit 2
fi

test_dst_prefix="${evidence_pkg_dir}/specula_committed_marker"

if ! command -v "${go_bin}" >/dev/null 2>&1; then
  if [[ -x /usr/local/go/bin/go ]]; then
    go_bin="/usr/local/go/bin/go"
  else
    echo "error: go binary not found on PATH" >&2
    exit 2
  fi
fi

copied_tests=()
for test_src in "${test_src_dir}"/*_test.go; do
  test_name="$(basename "${test_src}")"
  test_dst="${test_dst_prefix}_${test_name}"
  sed "s#\"github.com/cometbft/cometbft/evidence\"#\"${evidence_import_path}\"#" "${test_src}" > "${test_dst}"
  copied_tests+=("${test_dst}")
done
trap 'rm -f "${copied_tests[@]}"' EXIT

cd "${target_cometbft_root}"
timeout 120 "${go_bin}" test "${evidence_pkg}" -run 'TestSpeculaCommittedMarkerWriteFailure(ReacceptsEvidence|SurvivesRestart)$' -count=1 -v
