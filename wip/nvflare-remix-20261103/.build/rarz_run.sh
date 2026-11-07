#!/usr/bin/env bash
cd /home/ubuntu/nvflare-remix-20261103
export MIX_SPEC=/home/ubuntu/nvflare-remix-20261103/.build/snap-093118/spec MIX_BUILD=/home/ubuntu/nvflare-remix-20261103/.build/snap-093118/spec
for m in pay h30g; do for k in 1 2 3 5; do
  python3 scripts/run_mc.py rarz_${m}_k$k --mode sim --depth 200,100000000 --timeout 900 --workers 5 > .build/rarz_${m}_k$k.out 2>&1 &
done; done
wait; echo RARZ_DONE
