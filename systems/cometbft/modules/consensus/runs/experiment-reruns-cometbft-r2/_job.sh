#!/usr/bin/env bash
# Detached worker: clone pristine source, then run the Specula second pass.
# Isolated: unique name "cometbft-r2" (no case-studies/ collision) + explicit
# --artifact, so this NEVER reads or writes case-studies/cometbft*.
set -euo pipefail

WORK=/home/ubuntu/Specula/experiments/cometbft-r2
LAUNCH=/home/ubuntu/Specula/scripts/launch/launch_pipeline.sh
REPO=https://github.com/cometbft/cometbft
DESC="cometbft-r2|cometbft/cometbft|Go|Tendermint BFT"

cd "$WORK"
if [ ! -e src/.git ]; then
  echo "[$(date '+%F %T')] cloning $REPO -> src (shallow)"
  git clone --depth 1 "$REPO" src
else
  echo "[$(date '+%F %T')] src/ already present, reusing"
fi
echo "[$(date '+%F %T')] launching pipeline (name=cometbft-r2, artifact=$WORK/src)"
exec bash "$LAUNCH" --artifact="$WORK/src" "$DESC"
