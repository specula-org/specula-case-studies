#!/usr/bin/env bash
cd /home/ubuntu/nvflare-remix-20261103
for ph in 2 3 4 5; do
  python3 scripts/ckpt.py test_proc_s1l1a2 --grain JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=C,PaySrc=C,PayRcv=C,CommSJ=F,WfSJ=C,Net=R --faults spCrash,cpCrash,cjCrash,rpcTimeout,taskTimeout,deadClient,abort --sites 1 --launch 1 --attempt 2 --profile wfTolerant --phase $ph --n 2 &
done; wait
for f in checks/ckpt/test_proc_s1l1a2/*.trace; do echo "$f $(grep -c '^State' $f) steps; $(grep -m1 -o 'status |-> "[A-Z_]*"' ${f%.trace}.tla)"; done
