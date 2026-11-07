#!/usr/bin/env bash
R=/home/ubuntu/nvflare-remix-20261103; W=$R/.build/x7/tr6
cd $R/checks/mixes
for c in proc_allF_s2l1a2 allP_fam_s2l1a2 job_fam_s1l2a2 restart_allF_s2l1a2; do
  m=MC_x7f_h6S_${c}_t20
  (TLC_WORKERS=4 TLC_HEAP=8g timeout 1200 ../../scripts/tlc.sh tlc . $m $m.cfg -simulate file=$W/${c},num=12 -depth 1500 > $W/${c}.log 2>&1; python3 $R/.build/x7/parsetr.py $W/${c} rm > $W/${c}.parse 2>&1) &
done
wait
echo T7_DONE
