#!/usr/bin/env bash
cd /home/ubuntu/nvflare-remix-20261103
export MIX_SPEC=/home/ubuntu/nvflare-remix-20261103/.build/snap-094727/spec MIX_BUILD=/home/ubuntu/nvflare-remix-20261103/.build/snap-094727/spec
for m in h30g tc; do for k in 1 2 3 5; do
  python3 scripts/run_mc.py rarz2_${m}_k$k --mode sim --depth 250,100000000 --timeout 900 --workers 5 > .build/rarz2_${m}_k$k.out 2>&1 &
done; done
wait; echo RARZ2_DONE
