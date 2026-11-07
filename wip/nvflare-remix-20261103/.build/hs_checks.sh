#!/usr/bin/env bash
# Refinement re-checks after the DS shutdown call-return handshake (GPT item 2).
cd "$(dirname "$0")/.."
set -x
python3 scripts/pay_ref.py hs_rcv_nofault --src C --rcv F --check rcv --run --timeout 600 --workers 8 &
python3 scripts/pay_ref.py hs_rcv_nofault_neg --src C --rcv F --check rcv --negative --run --timeout 300 --workers 4 &
python3 scripts/pay_ref.py hs_src_nofault --src F --rcv C --check src --run --timeout 900 --workers 12 &
python3 scripts/pay_ref.py hs_src_nofault_neg --src F --rcv C --check src --negative --run --timeout 300 --workers 4 &
wait
python3 scripts/pay_ref.py hs_rcv_s10L --src C --rcv F --check rcv --faults cjCrash,taskTimeout,netLoss --run --timeout 1200 --workers 12 &
python3 scripts/pay_ref.py hs_src_s10 --src F --rcv C --check src --faults cjCrash,taskTimeout --run --timeout 1200 --workers 12 &
python3 scripts/gen_ref.py RunCJ F C --sites 1 --launch 2 --faults abort,admissionError,archiveError,cjCrash,deployError,launchError,outcomeReportFail,outcomeTimeout,resExpiry,rpcTimeout,storeError --run --timeout 900 --workers 8 &
python3 scripts/gen_ref.py WfSJ F C --sites 1 --faults taskTimeout --run --timeout 900 --workers 8 &
wait
echo HS_DONE
