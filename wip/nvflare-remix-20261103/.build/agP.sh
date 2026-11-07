#!/usr/bin/env bash
cd "$(dirname "$0")/.."
for n in agP_allC agP_allF agP_job agP_payfed agP_mixL; do
  python3 scripts/run_mc.py $n --mode sim --depth 100,100000000 --timeout 300 --workers 5 &
done
wait; echo AGP_DONE
