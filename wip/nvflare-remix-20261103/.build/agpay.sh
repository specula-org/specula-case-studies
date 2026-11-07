#!/usr/bin/env bash
cd "$(dirname "$0")/.."
python3 scripts/pay_ref.py ag_src_nofault --src F --rcv C --check src --run --timeout 1500 --workers 12 &
python3 scripts/pay_ref.py ag_rcv_s10L --src C --rcv F --check rcv --faults cjCrash,taskTimeout,netLoss --run --timeout 1500 --workers 10 &
python3 scripts/pay_ref.py ag_rcv_neg --src C --rcv F --check rcv --negative --run --timeout 300 --workers 2 &
python3 scripts/pay_ref.py ag_src_neg --src F --rcv C --check src --negative --run --timeout 300 --workers 2 &
wait
python3 scripts/pay_ref.py ag_src_s10 --src F --rcv C --check src --faults cjCrash,taskTimeout --run --timeout 1500 --workers 12
echo AGPAY_DONE
