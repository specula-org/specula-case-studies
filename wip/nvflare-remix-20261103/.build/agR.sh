#!/usr/bin/env bash
cd "$(dirname "$0")/.."
for n in agR_allC agR_allF agR_job agR_payfed agR_mixL; do
  python3 scripts/run_mc.py $n --mode sim --depth 100,100000000 --timeout 240 --workers 6 &
done
wait; echo AGR_DONE
