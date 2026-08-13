#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/cometbft" >&2
  exit 2
fi

target_cometbft_root="$1"
test_src_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_dst="${target_cometbft_root}/evidence/specula_committed_marker_repro_test.go"
go_bin="go"

if [[ ! -d "${target_cometbft_root}/evidence" ]]; then
  echo "error: ${target_cometbft_root} does not look like a CometBFT checkout" >&2
  exit 2
fi

if ! command -v "${go_bin}" >/dev/null 2>&1; then
  if [[ -x /usr/local/go/bin/go ]]; then
    go_bin="/usr/local/go/bin/go"
  else
    echo "error: go binary not found on PATH" >&2
    exit 2
  fi
fi

cp "${test_src_dir}/bugrepro_test.go" "${test_dst}"
trap 'rm -f "${test_dst}"' EXIT

cd "${target_cometbft_root}"
timeout 120 "${go_bin}" test ./evidence -run TestSpeculaCommittedMarkerWriteFailureReacceptsEvidence -count=1 -v
