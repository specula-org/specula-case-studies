#!/usr/bin/env bash
# Stop main-hunt JVMs for job/task BFS runs that the parallel hunt4p covers (*_p).
# Matches java processes only (comm == java), never shells. Exits with the main hunt.
main=$(pgrep -f '^python3 scripts/hunt.py hunt4 ')
while [ -n "$main" ] && kill -0 $main 2>/dev/null; do
  for p in $(pgrep -x java); do
    a=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
    case "$a" in
      *MC_h4B_job_s1l2a1_k1.tla*|*MC_h4B_job_s1l1a2_k1.tla*|*MC_h4R_job_s1l1a1_k2.tla*|*MC_h4B_task_s1l2a1_k1.tla*|*MC_h4B_task_s1l1a2_k1.tla*|*MC_h4R_task_s1l1a1_k2.tla*)
        echo "$(date +%T) dedup: stop $p $(echo "$a" | grep -o 'MC_h4[A-Za-z0-9_]*\.tla')"; kill -TERM $p;;
    esac
  done
  sleep 10
done
echo "$(date +%T) main hunt finished"
