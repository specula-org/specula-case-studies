#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
revision=3ac0104a567092139534c9022205d02281a2da41
case_name=${1:-all}
case "$case_name" in
  all|CR-1|CR-2|CR-3) ;;
  *) echo "Usage: bash run.sh [all|CR-1|CR-2|CR-3] [local-vsr-repository]" >&2; exit 2 ;;
esac
for command in git tar cargo python3 timeout; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 2; }
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/vsr-case-study.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
if [[ $# -ge 2 ]]; then
  source_git=$(cd -- "$2" && pwd)
else
  source_git="$scratch/upstream"
  git init -q "$source_git"
  git -C "$source_git" fetch -q --depth=1 https://github.com/penberg/vsr-rs.git "$revision"
fi
git -C "$source_git" cat-file -e "${revision}^{commit}"
export SOURCE_REPO="$scratch/source"
mkdir -p "$SOURCE_REPO" "$scratch/tmp"
git -C "$source_git" archive "$revision" | tar -x -C "$SOURCE_REPO"
export TMPDIR="$scratch/tmp"
export CARGO_TARGET_DIR="$scratch/build"
export BUILD_TARGET="$CARGO_TARGET_DIR"
export CARGO_BUILD_JOBS=2
echo "source_revision=$revision"
echo "source_tree=$(git -C "$source_git" rev-parse "${revision}^{tree}")"

if [[ "$case_name" == all || "$case_name" == CR-1 ]]; then
  timeout --kill-after=5s 10m bash "$script_dir/test_bugCR-1_existing_identity_restarts_as_new.sh"
fi
if [[ "$case_name" == all || "$case_name" == CR-2 ]]; then
  timeout --kill-after=5s 5m bash "$script_dir/test_bugCR-2_singleton_self_quorum.sh"
fi
if [[ "$case_name" == all || "$case_name" == CR-3 ]]; then
  timeout --kill-after=5s 2m python3 "$script_dir/test_bugCR-3_sender_stall.py"
fi
