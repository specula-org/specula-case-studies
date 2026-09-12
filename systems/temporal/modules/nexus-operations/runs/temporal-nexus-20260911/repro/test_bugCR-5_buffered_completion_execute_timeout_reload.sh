#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/confirmation/CR-5/worktree"

cd "$REPO"
go test -tags test_dep ./tests \
  -run 'TestNexusWorkflowTestSuiteHSM/TestBugCR5BufferedCompletionExecuteTimeoutReloadThenCancel' \
  -count=1 \
  -timeout=5m \
  -v
