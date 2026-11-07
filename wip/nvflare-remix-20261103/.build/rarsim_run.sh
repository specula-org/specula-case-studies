#!/usr/bin/env bash
cd /home/ubuntu/nvflare-remix-20261103
export MIX_SPEC=/home/ubuntu/nvflare-remix-20261103/.build/snap-081324/spec MIX_BUILD=/home/ubuntu/nvflare-remix-20261103/.build/snap-081324/spec
for d in C F; do for k in 1 2 3 99; do
  python3 scripts/run_mc.py rarsim_all${d}_k$k --mode sim --depth 150,100000000 --timeout 600 --workers 6 > .build/rarsim_all${d}_k$k.out 2>&1 &
done; done
wait; echo RARSIM_DONE
