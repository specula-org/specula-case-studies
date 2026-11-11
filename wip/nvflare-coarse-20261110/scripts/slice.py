#!/usr/bin/env python3
"""Port read/write relations between groups (STANDARD 10, slicing).

For every group module: the port variables its actions read (through the Ports-level
helper operators, expanded transitively), the port variables it writes (primed), the
message kinds it sends (owned kinds) and the kinds it receives (string literals of
kinds it does not own). Group B depends on group A if B reads A's port or receives a
kind A owns. owners(f): groups whose actions mention fault f (directly or through a
helper operator). slice(f) = owners(f) plus their neighbours in the dependency graph,
both directions (readers of what the owners write, and writers of what they read).

slice.py [--report]        print the graph and per-fault slices
library: graph(), owners(f), slice_of(faults)
"""
import json, re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SPEC = Path(__import__("os").environ.get("MIX_SPEC") or (ROOT / "spec"))
sys.path.insert(0, str(ROOT / "scripts"))
import gen_mix, rarity as R

PORT_MODULES = R.PORT_MODULES


def _reg():
    return gen_mix.load()


def _port_closure(ports):
    """operator name -> set of port variables it references (transitively)."""
    defs = {}
    for pm in PORT_MODULES:
        p = SPEC / f"{pm}.tla"
        if p.exists():
            defs.update(R.bodies(p.read_text()))
    direct = {n: {v for v in ports if re.search(r"\b" + v + r"\b", b.split("==", 1)[-1])} for n, b in defs.items()}
    refs = {n: {m for m in defs if m != n and re.search(r"\b" + m + r"\b", b.split("==", 1)[-1])} for n, b in defs.items()}
    out = {n: set(s) for n, s in direct.items()}
    ch = True
    while ch:
        ch = False
        for n in out:
            for m in refs[n]:
                if not out[m] <= out[n]:
                    out[n] |= out[m]; ch = True
    return out, defs


def graph():
    reg = _reg()
    ports = [p for p in reg["port_vars"] if p != "net"]
    pclos, pdefs = _port_closure(ports)
    fnames = set(json.loads((SPEC / "rarity.json").read_text())["weights"]) - {"_default"}
    # operator -> fault-name literals in its body, transitively
    fdir = {n: {f for f in re.findall(r'"(\w+)"', b.split("==", 1)[-1]) if f in fnames} for n, b in pdefs.items()}
    frefs = {n: {m for m in pdefs if m != n and re.search(r"\b" + m + r"\b", b.split("==", 1)[-1])} for n, b in pdefs.items()}
    fclos = {n: set(v) for n, v in fdir.items()}
    ch = True
    while ch:
        ch = False
        for n in fclos:
            for m in frefs[n]:
                if not fclos[m] <= fclos[n]:
                    fclos[n] |= fclos[m]; ch = True
    kinds_owner = {k: g for g, gd in reg["groups"].items() for k in gd["kinds"]}
    info = {}
    for g, gd in reg["groups"].items():
        rd, wr, rk, fl, dr = set(), set(), set(), set(), set()
        for v, vd in gd["variants"].items():
            src = gen_mix.strip_comments((SPEC / f"{vd['module']}.tla").read_text())
            body = src.split("====")[0]
            rd |= {p for p in ports if re.search(r"\b" + p + r"\b(?!')", body)}
            for n, s in pclos.items():
                if re.search(r"\b" + n + r"\b", body):
                    rd |= s
            wr |= {p for p in ports if re.search(r"\b" + p + r"'", body)}
            rk |= {k for k in kinds_owner if f'"{k}"' in body and kinds_owner[k] != g}
            fl |= set(R.fault_names(body))
            fl |= {f for f in re.findall(r'"(\w+)"', body)}
            for n, fs in fclos.items():          # faults used through a helper operator
                if re.search(r"\b" + n + r"\b", body):
                    fl |= {f for f in fs if f != "?"}
            dr |= {p for p in ports if re.search(r"\b" + p + r"\b(?!')", body)}
        if gd.get("port"):
            wr.add(gd["port"])
        info[g] = dict(reads=rd - wr, writes=wr, recv=rk, sends=set(gd["kinds"]), words=fl, direct=dr - wr)
    return info, kinds_owner


def deps(info, kinds_owner, strict=False):
    """B depends on A: B reads A's port or receives a kind A owns. strict: only reads
    written in B's own module text (not through the Ports-level process helpers)."""
    port_owner = {p: g for g, i in info.items() for p in i["writes"]}
    d = {g: set() for g in info}
    for b, i in info.items():
        for p in (i["direct"] if strict else i["reads"]):
            if p in port_owner and port_owner[p] != b:
                d[b].add(port_owner[p])
        for k in i["recv"]:
            d[b].add(kinds_owner[k])
    return d   # d[b] = groups b depends on


CHANNEL = {"netLossJobSP": "JobSP", "netLossJobCP": "JobCP", "netLossRunCJ": "RunCJ", "netLossTaskCJ": "TaskCJ",
           "netLossCommSJ": "CommSJ", "netLossWfSJ": "WfSJ", "netLossPaySrc": "PaySrc", "netLossPayRcv": "PayRcv",
           "netLossSwarm": "Swarm"}


def owners(info, f, fault_names):
    """groups whose module (or a helper it uses) mentions fault f. A loss channel
    netLoss<G> is owned by Net, the sender G and the receivers of G's message kinds."""
    if f in CHANNEL:
        g = CHANNEL[f]
        return {"Net", g} | {b for b, i in info.items() if i["recv"] & info[g]["sends"]}
    return {g for g, i in info.items() if f in i["words"] and not (f == "netLoss" and False)}


def slice_of(faults, strict=True):
    """strict (default): neighbours by the reads written in a group's own module text and by
    received message kinds; reads made only through the Ports-level process-liveness helpers
    do not make a group a neighbour (outside the slice it still runs and sees the death)."""
    info, ko = _G()
    d = deps(info, ko, strict)
    own = set()
    for f in faults:
        own |= owners(info, f, None)
    if "netLoss" in faults:
        own.add("Net")
    s = set(own)
    for g in own:
        s |= d[g]                                   # what the owners read
        s |= {b for b in d if g in d[b]}            # who reads the owners
    return sorted(own), sorted(s)


def adjacent(a, b, strict=True):
    """two groups are adjacent: the same group, or one depends on the other (strict reads)."""
    info, ko = _G()
    d = deps(info, ko, strict)
    return a == b or a in d[b] or b in d[a]


_cache = {}
def _G():
    if "g" not in _cache:
        _cache["g"] = graph()
    return _cache["g"]


if __name__ == "__main__":
    info, ko = graph()
    d = deps(info, ko)
    ds = deps(info, ko, strict=True)
    for g in info:
        print(f"{g:8s} strict-depends on {sorted(ds[g])}")
    for g in info:
        print(f"{g:8s} depends on {sorted(d[g])}")
    if "--report" in sys.argv:
        fs = sorted(json.loads((SPEC / "rarity.json").read_text())["weights"])
        for f in fs:
            if f == "_default":
                continue
            o, s = slice_of([f])
            print(f"{f:20s} owners={o} slice={len(s)} out={sorted(set(info) - set(s))}")
