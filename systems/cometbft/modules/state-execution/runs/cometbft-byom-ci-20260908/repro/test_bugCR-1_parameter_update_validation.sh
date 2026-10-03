#!/usr/bin/env bash
set -euo pipefail

repro_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repro_output_dir=$(dirname -- "$repro_script_dir")
repro_repo_dir="$repro_output_dir/confirmation/CR-1/worktree"
repro_test_source="$repro_script_dir/test_bugCR-1_parameter_update_validation_test.go"
repro_test_link="$repro_repo_dir/internal/state/cr1_parameter_update_repro_test.go"

if [[ ! -f "$repro_test_source" ]]; then
	echo "missing reproduction source: $repro_test_source" >&2
	exit 1
fi

if [[ -e "$repro_test_link" || -L "$repro_test_link" ]]; then
	echo "refusing to overwrite existing path: $repro_test_link" >&2
	exit 1
fi

ln -s "$repro_test_source" "$repro_test_link"
trap 'unlink "$repro_test_link"' EXIT

cd "$repro_repo_dir"
timeout 10m go test -count=1 -v ./internal/state \
	-run 'TestBugCR1(ParameterUpdateValidationAndInstallation|EscalationSoundness)$'
