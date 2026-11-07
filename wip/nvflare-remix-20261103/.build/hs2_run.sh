#!/usr/bin/env bash
cd /home/ubuntu/nvflare-remix-20261103
export MIX_INCLUDE_WIP=all
set -x
python3 scripts/pay_ref.py hs2_src_nofault --src F --rcv C --check src --run --timeout 1200 --workers 12 &
python3 scripts/pay_ref.py hs2_src_s10 --src F --rcv C --check src --faults cjCrash,taskTimeout --run --timeout 1500 --workers 12 &
python3 scripts/pay_ref.py hs2_src_nofault_neg --src F --rcv C --check src --negative --run --timeout 300 --workers 4 &
MIX_SPEC=/home/ubuntu/nvflare-remix-20261103/.build/snap-084211/spec MIX_BUILD=/home/ubuntu/nvflare-remix-20261103/.build/snap-084211/spec python3 scripts/run_mc.py hs2_wit --mode sim --depth 200,100000000 --timeout 600 --workers 8 &
MIX_SPEC=/home/ubuntu/nvflare-remix-20261103/.build/snap-084211/spec MIX_BUILD=/home/ubuntu/nvflare-remix-20261103/.build/snap-084211/spec python3 scripts/run_mc.py hs2_dl --mode sim --depth 200,100000000 --timeout 900 --workers 8 &
wait; echo HS2_DONE
