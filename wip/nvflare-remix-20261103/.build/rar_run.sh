#!/usr/bin/env bash
cd /home/ubuntu/nvflare-remix-20261103
export MIX_SPEC=/home/ubuntu/nvflare-remix-20261103/.build/snap-081324/spec MIX_BUILD=/home/ubuntu/nvflare-remix-20261103/.build/snap-081324/spec
for n in rar_allC_k0 rar_allC_k1 rar_allC_k2 rar_allC_k3 rar_allC_k99; do
  python3 scripts/run_mc.py $n --timeout 900 --workers 10 > .build/$n.out 2>&1 &
done
wait; echo RAR_DONE
