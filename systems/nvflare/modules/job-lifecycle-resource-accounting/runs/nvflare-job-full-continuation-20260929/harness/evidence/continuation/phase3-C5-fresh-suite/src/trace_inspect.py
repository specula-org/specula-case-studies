#!/usr/bin/env python3
# Copyright (c) 2026, NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Inspect an nvflare-job NDJSON trace, optionally around the point where TLC trace validation got stuck.

  python3 harness/src/trace_inspect.py traces/<name>.ndjson                 # compact listing of every event
  python3 harness/src/trace_inspect.py traces/<name>.ndjson --tlc-log L     # window around the first unmatched event
  python3 harness/src/trace_inspect.py traces/<name>.ndjson --from 20 --to 40 [--jobs j1,j2]
"""
import argparse
import json
import re


def compact(evt, jobs):
    s = evt["state"]
    parts = []
    for jn in jobs:
        j = s["jobs"][jn]
        rp = j["run_process"]
        ex = j["exception_process"]
        parts.append(
            f"{jn}:{j['status'].replace('FINISHED:', 'F:')[:14]}"
            f" rp={'Y' if rp['present'] else '-'}{('/f' if rp['finished'] else '') if rp['present'] else ''}"
            f"{('/rc' + str(rp['rc'])) if rp['present'] and rp['rc'] else ''}"
            f" exc={'Y/rc' + str(ex['rc']) if ex['present'] else '-'}"
            f" pend={','.join(j['pending']['set']) if j['pending']['present'] else '-'}"
            f" lat={j['latched'].replace('FINISHED:', '')[:6] if j['latched'] != 'None' else '-'}"
            f" ab={'Y' if j['run_aborted'] else '-'} sj={j['sj'][:3]}"
        )
    cl = []
    for cn, c in s["clients"].items():
        if not c["alive"]:
            cl.append(f"{cn}:DEAD")
            continue
        regs = []
        for jn in jobs:
            cj = c["jobs"][jn]
            r = cj["registration"]
            if r["present"] or cj["cj"] != "None" or cj["allocated"] or cj["starting"]["present"]:
                regs.append(
                    f"{jn}[{r['st'][:5] if r['present'] else '-'}{'!' if r['abort_req'] else ''}"
                    f"{'' if r['attached'] or not r['present'] else '~'} cj={cj['cj'][:3]}"
                    f"{' st=' + ','.join(cj['starting']['units']) if cj['starting']['present'] else ''}"
                    f"{' al=' + ','.join(cj['allocated']) if cj['allocated'] else ''}]"
                )
        resv = ",".join(f"{r['job']}@{r['att']}:{'+'.join(r['units'])}/t{r['ttl']}" for r in c["reserved"])
        cl.append(f"{cn}: free={'+'.join(c['free']) or '-'} resv={resv or '-'} {' '.join(regs)}")
    return (
        f"slots={','.join(s['scheduled_jobs']) or '-'} run={','.join(s['running_jobs']) or '-'} "
        f"sess={','.join(s['sessions'])} tag={','.join(s['tagged']) or '-'} | " + " | ".join(parts) + " || " + " || ".join(cl)
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--tlc-log")
    ap.add_argument("--from", dest="lo", type=int, default=None)
    ap.add_argument("--to", dest="hi", type=int, default=None)
    ap.add_argument("--jobs", default=None)
    ap.add_argument("--window", type=int, default=6)
    a = ap.parse_args()
    lines = [json.loads(x) for x in open(a.trace) if x.strip()]
    cfg = next((x for x in lines if x.get("tag") == "config"), {})
    ev = [x for x in lines if x.get("tag") == "trace"]
    jobs = a.jobs.split(",") if a.jobs else cfg.get("jobs", [])
    lo, hi = a.lo, a.hi
    if a.tlc_log:
        ls = re.findall(r"/\\ l = (\d+)", open(a.tlc_log).read())
        if ls:
            stuck = int(ls[-1])
            print(f"TLC consumed {stuck - 1} events; first unmatched event is #{stuck} (seq {ev[stuck - 1]['seq']})")
            lo = max(1, stuck - a.window)
            hi = min(len(ev), stuck + 2)
    lo = lo or 1
    hi = hi or len(ev)
    for i in range(lo - 1, hi):
        x = ev[i]
        e = x["event"]
        m = e.get("msg")
        ms = f" msg={m['type']}({m['job']},{m['cl']},att={m['att']},ok={m['ok']},code={m['code']},flag={m['flag']})" if m else ""
        arg = f" arg={e['arg']}" if e.get("arg") else ""
        err = f" ERROR={x['error']}" if x.get("error") else ""
        print(f"#{i + 1:<4} {e['name']:<24} job={e['job']:<4} cl={e['cl']:<4}{ms}{arg}{err}  [{x.get('thread', '')[:28]}]")
        print(f"       {compact(e, jobs)}")


if __name__ == "__main__":
    main()
