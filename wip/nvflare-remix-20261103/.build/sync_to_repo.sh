#!/usr/bin/env bash
# Sync the remix workspace's sources, docs and result summaries into the case-studies
# worktree (branch backup/nvflare-remix-20261105). Additive (no deletes). Generated MC
# modules, checkpoints, TLC logs, scratch dirs, inputs/jobs/lib/poc payloads are not synced.
set -euo pipefail
SRC=/home/ubuntu/nvflare-remix-20261103
DST=/home/ubuntu/specula-case-studies-nvflare-remix-20261105/wip/nvflare-remix-20261103
DRY=${DRY:-}
for f in RESULTS.md DESIGN.md GOAL.md; do rsync -a $DRY "$SRC/$f" "$DST/$f"; done
for d in spec scripts plans notes; do
  rsync -a $DRY --exclude='__pycache__/' --exclude='*.pyc' "$SRC/$d/" "$DST/$d/"
done
rsync -a $DRY --exclude='/mixes/' --exclude='/ckpt*/' --exclude='__pycache__/' "$SRC/checks/" "$DST/checks/"
mkdir -p "$DST/.build/x7"
rsync -a $DRY --include='*.sh' --include='*.py' --exclude='*' "$SRC/.build/" "$DST/.build/"
rsync -a $DRY --include='*.py' --include='*.sh' --include='*.json' --include='*.out' --include='toy/' --include='toy/*.tla' --include='toy/*.cfg' --exclude='*' "$SRC/.build/x7/" "$DST/.build/x7/"
mkdir -p "$DST/.build/x10"
rsync -a $DRY --include='*.py' --include='*.sh' --exclude='*' "$SRC/.build/x10/" "$DST/.build/x10/"
mkdir -p "$DST/.build/x11"
rsync -a $DRY --include='*.py' --include='*.sh' --include='*.jsonl' --exclude='*' "$SRC/.build/x11/" "$DST/.build/x11/"
