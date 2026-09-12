#!/usr/bin/env bash
set -euo pipefail

cd /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-5/worktree

LOG=/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-5/repro-output.txt
timeout 10m go test -tags test_dep ./tests -run '^TestCR5ResetStagedChildCompletionAndDeletion$' -count=1 -timeout=8m -v | tee "$LOG"
