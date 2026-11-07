#!/usr/bin/env bash
# Sync the remix workspace's sources, docs and result summaries into the case-studies
# worktree (branch backup/nvflare-remix-20261105). Generated MC modules, checkpoints,
# TLC logs and scratch dirs are not synced (regenerable; gigabytes).
set -euo pipefail
SRC=/home/ubuntu/nvflare-remix-20261103/
DST=/home/ubuntu/specula-case-studies-nvflare-remix-20261105/wip/nvflare-remix-20261103/
rsync -a -n --stats \
  --exclude='/.work/' --exclude='/.tmp/' --exclude='/.tlc/' --exclude='/logs/' \
  --exclude='/checks/mixes/' --exclude='/checks/ckpt*/' --exclude='__pycache__/' --exclude='*.pyc' \
  --exclude='/.build/x7/tr*/' --exclude='/.build/x7/cknet/' --exclude='/.build/x7/sp/' --exclude='/.build/x7/toy/*.st' \
  --exclude='/.build/snap-*/' --exclude='/.build/regen/' \
  --include='/.build/' --include='/.build/*.sh' --include='/.build/*.py' --include='/.build/x7/' \
  --include='/.build/x7/***' --exclude='/.build/*' \
  "$SRC" "$DST"
