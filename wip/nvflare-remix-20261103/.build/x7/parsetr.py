#!/usr/bin/env python3
"""Parse TLC simulation trace dumps: per trace, action histogram before/after the job turns terminal,
level of terminal status, last level where any port variable changed, last level with any change."""
import re, sys, json, hashlib, collections, glob, os
PORT = ("net", "pJobSP", "pJobCP", "pRunCJ", "pTaskCJ", "pPaySrc", "pPayRcv", "pCommSJ", "pWfSJ", "pTrainer")
def states(path):
    act, buf = None, []
    for line in open(path):
        if line.startswith("\\* <"):
            if buf: yield act, buf
            act = line[4:].split(" ", 1)[0]; buf = []
        elif line.startswith("STATE_") or line.startswith("----") or line.startswith("===="):
            continue
        else:
            buf.append(line)
    if buf: yield act, buf
def split_vars(buf):
    v, cur = {}, None
    for line in buf:
        m = re.match(r"^/\\ (\w+) = ", line)
        if m: cur = m.group(1); v[cur] = [line]
        elif cur: v[cur].append(line)
    return {k: hashlib.md5("".join(x).encode()).hexdigest() for k, x in v.items()}, v
out = []
for f in sorted(glob.glob(sys.argv[1] + "_*")):
    prev = None; term = None; run = None; fuse = None; fault = None; lastport = 0; lastany = 0; acts = []; n = 0
    for i, (a, buf) in enumerate(states(f), 1):
        h, raw = split_vars(buf); n = i
        acts.append(a)
        if term is None and 'terminal |-> "none"' not in "".join(raw.get("pJobSP", [])):
            term = i
        m = re.search(r"^/\\ fuse = (\d+)", "".join(raw.get("fuse", [])), re.M)
        if m and fuse is None: fuse = int(m.group(1))
        if fault is None and raw.get("rare") and not "".join(raw["rare"]).strip().endswith("= 0"):
            fault = i
        if run is None and 'status |-> "RUNNING"' in "".join(raw.get("pJobSP", [])):
            run = i
        if prev:
            if any(h.get(p) != prev.get(p) for p in PORT): lastport = i
            if any(h.get(k) != prev.get(k) for k in h if k != "rare"): lastany = i
        prev = h
    cut = term or n
    pre = collections.Counter(acts[:cut]); post = collections.Counter(acts[cut:])
    out.append(dict(file=os.path.basename(f), len=n, term=term, run=run, fuse=fuse, fault=fault, lastport=lastport, lastany=lastany,
                    pre=pre.most_common(8), post=post.most_common(6)))
    if len(sys.argv) > 2 and sys.argv[2] == "rm": os.remove(f)
json.dump(out, open(sys.argv[1] + ".json", "w"), indent=0)
print(len(out), "traces parsed")
