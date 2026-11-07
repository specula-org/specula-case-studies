#!/usr/bin/env bash
cd "$(dirname "$0")/.."
for n in agW_allC agW_allF agW_fed agW_commF agW_mixL; do
  python3 scripts/run_mc.py $n --mode sim --depth 100,100000000 --timeout 300 --workers 5 &
done
wait; echo AGW_DONE
