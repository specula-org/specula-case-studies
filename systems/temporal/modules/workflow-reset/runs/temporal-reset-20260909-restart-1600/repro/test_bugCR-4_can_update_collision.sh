#!/usr/bin/env bash
set -euo pipefail

repo="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-4/worktree"

cd "$repo"
mkdir -p "$repo/.gotmp"
export TMPDIR="$repo/.gotmp"
export GOTMPDIR="$repo/.gotmp"
echo "repo=$(pwd)"
echo "head=$(git rev-parse HEAD)"
echo "tmpdir=$TMPDIR"
echo "test=TestBugCR4ResetReapplyCollidingUpdateIDsAcrossCAN"
timeout 10m go test -tags=test_dep ./tests -run '^TestBugCR4ResetReapplyCollidingUpdateIDsAcrossCAN$' -count=1 -vet=off -p=1 -v
