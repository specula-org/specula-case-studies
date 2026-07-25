#!/usr/bin/env bash
# Detached worker: clone pristine source, then run the HotShot THIRD pass
# (focused on upgrade / consensus-DA interface / storage-decide).
# Isolated: unique name "hotshot-r3" (no case-studies/ collision) + explicit
# --artifact, so this NEVER reads or writes case-studies/hotshot.
set -euo pipefail

WORK=/home/ubuntu/Specula/experiments/hotshot-r3
LAUNCH=/home/ubuntu/Specula/scripts/launch/launch_pipeline.sh
REPO=https://github.com/EspressoSystems/espresso-network
DESC="hotshot-r3|EspressoSystems/espresso-network|Rust|HotStuff-2 BFT (Malkhi-Nayak 2023)"

cd "$WORK"
if [ ! -e src/.git ]; then
  echo "[$(date '+%F %T')] cloning $REPO -> src (shallow)"
  git clone --depth 1 "$REPO" src
else
  echo "[$(date '+%F %T')] src/ already present, reusing"
fi
echo "[$(date '+%F %T')] launching pipeline (name=hotshot-r3, artifact=$WORK/src)"
exec bash "$LAUNCH" --artifact="$WORK/src" "$DESC"
