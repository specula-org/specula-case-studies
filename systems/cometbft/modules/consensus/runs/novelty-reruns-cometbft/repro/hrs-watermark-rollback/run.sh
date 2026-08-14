#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 /path/to/cometbft" >&2
  echo "   or: COMETBFT_SRC=/path/to/cometbft $0" >&2
}

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

target_root="${1:-${COMETBFT_SRC:-}}"
if [[ -z "${target_root}" ]]; then
  usage
  exit 2
fi

target_root="$(cd "${target_root}" && pwd)"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
privval_dir="${target_root}/privval"
test_dst="${privval_dir}/specula_hrs_rollback_double_sign_test.go"
test_src="${here}/filepv_rollback_double_sign_test.go"
go_bin="${GO:-go}"

if [[ ! -f "${target_root}/go.mod" || ! -f "${target_root}/privval/file.go" || ! -f "${target_root}/libs/tempfile/tempfile.go" ]]; then
  echo "error: ${target_root} does not look like a CometBFT checkout" >&2
  exit 2
fi

if [[ -e "${test_dst}" ]]; then
  echo "error: refusing to overwrite existing ${test_dst}" >&2
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

if ! command -v strace >/dev/null 2>&1; then
  echo "error: strace is required for the syscall probe" >&2
  exit 2
fi

cp "${test_src}" "${test_dst}"
trace_file="$(mktemp -t specula-hrs-strace.XXXXXX)"
probe_log="$(mktemp -t specula-hrs-probe.XXXXXX)"
test_bin="$(mktemp -t specula-privval-test.XXXXXX)"
cleanup() {
  rm -f "${test_dst}" "${trace_file}" "${probe_log}" "${test_bin}"
}
trap cleanup EXIT

cd "${target_root}"

echo "== rollback consequence test =="
timeout 5m "${go_bin}" test ./privval -run '^TestSpeculaHRSRollbackAllowsConflictingVoteSignatures$' -count=1 -v

echo
echo "== real SignVote syscall probe =="
timeout 5m "${go_bin}" test -c -o "${test_bin}" ./privval
timeout 2m strace -f -yy \
  -e trace=openat,open,renameat,renameat2,rename,fsync,fdatasync,syncfs \
  -o "${trace_file}" \
  "${test_bin}" -test.run '^TestSpeculaFilePVSignVoteWritesHRSStateThroughAtomicRename$' -test.v \
  >"${probe_log}" 2>&1
cat "${probe_log}"

echo
echo "== relevant syscalls =="
grep -E 'write-file-atomic|priv_validator_state\.json|fsync|fdatasync|syncfs' "${trace_file}" | grep -v ENOENT || true

rename_count="$(grep -Ec 'rename(at2|at)?\(.*priv_validator_state\.json' "${trace_file}" || true)"
sync_count="$(grep -Ec '(fsync|fdatasync|syncfs)\(' "${trace_file}" || true)"
osync_count="$(grep -Ec 'write-file-atomic.*O_SYNC' "${trace_file}" || true)"

echo
echo "open temp file with O_SYNC calls        : ${osync_count}"
echo "rename calls to priv_validator_state.json : ${rename_count}"
echo "fsync/fdatasync/syncfs calls              : ${sync_count}"

if [[ "${osync_count}" -ge 1 && "${rename_count}" -ge 1 && "${sync_count}" -eq 0 ]]; then
  echo
  echo "SPECULA_HRS_DURABILITY_GAP: SignVote persisted the HRS state through an atomic rename without a parent-directory sync."
  exit 0
fi

echo
echo "SPECULA_HRS_DURABILITY_GAP_NOT_REPRODUCED: expected osync>=1, rename>=1 and sync calls=0, got osync=${osync_count}, rename=${rename_count}, sync=${sync_count}."
exit 1
