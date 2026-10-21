#!/usr/bin/env python3
"""Normalize recorded identities and timestamps without replaying the model."""

import argparse
import collections
import hashlib
import json
from pathlib import Path
import re

SOURCE = "0c60537098f4c2949ad2d382aaf499de72263d76"
OWNER_EVENTS = set("MappedVmoNew VmarProtectTake VmarRemoveNext MappedVmoDupAtOffset VmMappingSplit VmarInsertRest VmMappingProtect MappedVmoDropUnmapped MappedVmoDupForMerge MappedVmoDropMergeSelf MappedVmoDropMergeNeighbor VmarInsertMapping".split())
TREE_EVENTS = set("VmarLock VmarProtectTake VmarRemoveNext VmarInsertRest MappedVmoDropMergeNeighbor VmarInsertMapping VmarUnlock".split())
SEAL_EVENTS = set("MemfdAddSealsLock MemfdAddSealsCheck MemfdPublishSeals MemfdAddSealsUnlock MemfdGetSeals".split())
PTE_EVENTS = {"CursorUnmap", "CursorProtect", "HandlePageFault"}
NEW_EVENTS = {"MappedVmoNew", "MappedVmoDupAtOffset", "MappedVmoDupForMerge"}
DROP_EVENTS = {"MappedVmoDropUnmapped", "MappedVmoDropMergeSelf", "MappedVmoDropMergeNeighbor"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def pages(mask):
    require(0 <= mask < 8, "page bitset outside three-page abstraction")
    return [p for p in range(3) if mask & (1 << p)]


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


def normalize(case, trace_dir, raw_dir, event_names):
    name = case["setup"]["name"]
    events = case["events"]
    require(events, f"{name}: empty trace")
    ids = {row["thread"]: row for row in case["ids"]}
    require(1 in ids, f"{name}: missing bootstrap identity")
    first = ids[1]
    require(first["counters"] == [0, 0, 0], f"{name}: nonempty initial counter")
    require(first["seals"] == [case["setup"]["initial_seals"]] * 3, f"{name}: initial seal mismatch")
    require(first["modes"] == [2, 2, 0] == case["setup"]["modes"], f"{name}: unexpected access modes")
    require(len(set(first["files"])) == 3, f"{name}: descriptions are duplicated")
    require(len(set(first["inodes"])) == 1 and len(set(first["vmos"])) == 1, f"{name}: inconsistent backing identity")
    require(case["setup"]["eof_bytes"] == 12288, f"{name}: unexpected EOF")
    for row in ids.values():
        require(all(row[key] == first[key] for key in ("files", "inodes", "vmos", "modes", "fds")), f"{name}: thread identities differ")
        require(row["tsc_hz"] > 0 and row["tsc_hz"] == first["tsc_hz"], f"{name}: inconsistent TSC frequency")
    per_thread = collections.defaultdict(list)
    for event in events:
        require(event["tag"] == "trace" and event["event"] in event_names, f"{name}: unknown event")
        require(0 < event["start"] <= event["end"], f"{name}: invalid timebox")
        per_thread[event["thread"]].append(event)
    for thread, rows in per_thread.items():
        require(thread in {"t1", "t2"} and int(thread[1:]) in ids, f"{name}: unregistered thread")
        if len(ids) == 2:
            require(ids[int(thread[1:])]["num_cpus"] >= 2, f"{name}: SMP capture required")
            require(all(0 <= e["cpu"] < first["num_cpus"] for e in rows), f"{name}: invalid observed CPU")
        meta = [row for row in case["meta"] if f't{row["thread"]}' == thread]
        require(len(meta) == 1 and meta[0]["dropped"] == 0 and meta[0]["events"] == len(rows), f"{name}/{thread}: missing or dropped capture")
        require(all(a["end"] <= b["start"] for a, b in zip(rows, rows[1:])), f"{name}/{thread}: overlapping local source boundaries")
        serial = 0
        inside = False
        for e in rows:
            if e["event"] == "SyscallEnter":
                require(not inside and e["local"]["serial"] == serial + 1, f"{name}: missing syscall boundary")
                serial += 1
                inside = True
            require(inside and serial == e["local"]["serial"], f"{name}: invalid operation identity")
            if e["event"] == "SyscallReturn":
                inside = False
        require(not inside, f"{name}/{thread}: unterminated syscall")
        (raw_dir / f"{name}.{thread}.ndjson").write_text("".join(json.dumps(e) + "\n" for e in rows))

    # Owner mutations are serialized by the existing VMAR lock. A raw token
    # remains unique after its small normalized slot becomes reusable.
    slots = {0: 0}
    generations = {0: 0}
    free = set(range(1, 7))
    live = set()
    for e in sorted(events, key=lambda e: e["end"]):
        if e["event"] in NEW_EVENTS:
            for owner in e["owners"]:
                raw = owner["id"]
                require(raw not in slots and free, f"{name}: duplicate token or owner-pool exhaustion")
                slot = min(free)
                free.remove(slot)
                slots[raw] = slot
                live.add(raw)
                if e["event"] == "MappedVmoNew":
                    generations[raw] = len(generations)
        elif e["event"] in DROP_EVENTS:
            for owner in e["owners"]:
                raw = owner["id"]
                require(raw in live, f"{name}: destruction of an unknown owner")
                live.remove(raw)
                free.add(slots[raw])
    file_ids = dict(zip(first["files"], ("rw", "rw2", "ro")))
    selections = {}
    for meta in case["meta"]:
        for serial, hint, address, length in meta["selections"]:
            require(address % 4096 == 0 and length % 4096 == 0, f"{name}: unaligned selected range")
            lo, hi = (address - 0x40000000) // 4096, (address + length - 0x40000000) // 4096
            require(0 <= lo < hi <= 3, f"{name}: selected range is outside the abstraction")
            selections[(f't{meta["thread"]}', serial)] = (hint, lo, hi)

    def owner(raw):
        record = dict(raw)
        record["id"] = slots[record["id"]]
        if record["role"] == "free":
            record["fd"] = "rw"
        else:
            require(record["file"] in file_ids and record["vmo"] == first["vmos"][0], f"{name}: unknown file or VMO")
            record["fd"] = file_ids[record["file"]]
            require(0 <= record["lo"] < record["hi"] <= 3, f"{name}: mapping outside address abstraction")
        del record["file"], record["vmo"]
        record["generations"] = [generations[g] for g in record["generations"]]
        return record

    def owner_list(rows):
        return sorted((owner(row) for row in rows), key=lambda o: o["id"])

    stamps = sorted({e[k] for e in events for k in ("start", "end")})
    compressed = {stamp: i + 1 for i, stamp in enumerate(stamps)}
    normalized = []
    coverage = collections.Counter()
    for raw in events:
        event = raw["event"]
        coverage[event] += 1
        local = dict(raw["local"])
        local["request"] = dict(local["request"])
        selection = selections.get((raw["thread"], local["serial"]))
        if selection:
            hint, lo, hi = selection
            require(local["request"]["kind"] == "map", f"{name}: selection belongs to another syscall")
            old_lo = local["request"]["lo"]
            local["request"].update(lo=lo, hi=hi)
            if event not in ("SyscallEnter", "MmapFdMode") and local["last_end"] == old_lo:
                local["last_end"] = lo
            if event == "VmarLock":
                local["queue"] = [o for o in raw["tree"] if o["lo"] < hi and lo < o["hi"]]
        local["queue"] = [{k: o[k] for k in ("lo", "hi", "perms", "may")} for o in local["queue"]]
        local["rest"] = [slots[x] for x in local["rest"] if x]
        for key in ("cur", "tmp", "neighbor"):
            local[key] = slots[local[key]]
        for key in ("done", "touched"):
            local[key] = pages(local[key])
        local["generation"] = generations[local["generation"]]
        state = {"local": local}
        if event in OWNER_EVENTS:
            state["owners"] = owner_list(raw["owners"])
        if event in TREE_EVENTS:
            state["tree"] = owner_list(raw["tree"])
        if raw["counter"] is not None:
            state["counter"] = raw["counter"]
        if event in SEAL_EVENTS or (event == "MemfdCheckWritable" and local["checked"]):
            require(raw["seals"] is not None, f"{name}: missing locked seal snapshot")
            state["seals"] = raw["seals"]
        if event in ("VmarLock", "VmarUnlock"):
            state["vmar_owner"] = raw["thread"] if event == "VmarLock" else "none"
        if event in ("MemfdAddSealsLock", "MemfdAddSealsUnlock"):
            state["seal_owner"] = raw["thread"] if event == "MemfdAddSealsLock" else "none"
        if event in PTE_EVENTS:
            state["ptes"] = [{"addr": a, "generation": generations[g], "perms": p} for a, g, p in raw["ptes"]]
        if event == "DispatchTlbFlush":
            state["dispatched"] = local["touched"]
        if event == "SyncTlbFlush":
            state["completed"] = local["touched"]
        if event == "SyscallReturn":
            state["return_value"] = raw["return_value"]
            if local["request"]["kind"] == "map" and raw["return_value"] >= 0:
                r = local["request"]
                require(raw["return_value"] == 0x40000000 + r["lo"] * 4096, f"{name}: selected allocation differs from request; capture selection before normalization")
        row = {"tag": "trace", "event": event, "thread": raw["thread"],
               "start": compressed[raw["start"]], "end": compressed[raw["end"]], "state": state}
        if event == "SyscallEnter":
            row["args"] = local["request"]
        if event in ("CursorUnmap", "CursorProtect"):
            row["range"] = raw["range"]
        normalized.append(row)
    setup = {"tag": "setup", "source": SOURCE, "num_pages": 3, "owner_slots": 6,
             "allow_sealing": case["setup"]["allow_sealing"], "page_size": 4096,
             "base_address": 0x40000000, "eof_bytes": 12288, "initial_counter": first["counters"][0],
             "initial_seals": first["seals"][0], "inode": "memfd0", "vmo": "vmo0",
             "fd_modes": {"rw": "O_RDWR", "rw2": "O_RDWR", "ro": "O_RDONLY"}}
    path = trace_dir / f"{name}.ndjson"
    path.write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in [setup] + normalized))
    cross = [(a, b) for a in per_thread.get("t1", []) for b in per_thread.get("t2", [])]
    overlap = [(a, b) for a, b in cross if a["start"] <= b["end"] and b["start"] <= a["end"]]
    cross_cpu = [(a, b) for a, b in overlap if a["cpu"] != b["cpu"]]
    manifest = {"name": name, "events": len(events), "identities": case["ids"], "capture_receipts": case["meta"],
                "owner_tokens": slots, "generations": generations, "clock": "fenced OSTD x86 TSC",
                "timestamp_dictionary": stamps, "coverage": coverage, "cross_thread_pairs": len(cross),
                "overlapping_pairs": len(overlap), "overlap_fraction": len(overlap) / len(cross) if cross else 0,
                "cross_cpu_overlapping_pairs": len(cross_cpu),
                "overlap_events": [[a["event"], b["event"]] for a, b in overlap],
                "cpus": {t: sorted({e["cpu"] for e in rows}) for t, rows in per_thread.items()},
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    write_json(raw_dir / f"{name}.manifest.json", manifest)
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--spec", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    args.raw.mkdir(parents=True, exist_ok=True)
    spec = args.spec.read_text()
    names = set(re.findall(r'"([A-Za-z]+)"', re.search(r"EventNames == \{([^}]+)\}", spec).group(1)))
    cases = []
    case = None
    completed = False
    for line in args.log.read_text(errors="replace").splitlines():
        if "SPECULA_BEGIN " in line:
            require(case is None, "nested scenario markers")
            case = {"setup": json.loads(line.split("SPECULA_BEGIN ", 1)[1]), "events": [], "ids": [], "meta": []}
        elif "SPECULA_END" in line:
            require(case is not None, "orphan scenario end")
            cases.append(case)
            case = None
        elif "SPECULA_TEST_EXIT " in line:
            require(line.split("SPECULA_TEST_EXIT ", 1)[1].strip() == "0", "guest assertions failed")
            completed = True
        else:
            for marker, key in (("SPECULA_RAW ", "events"), ("SPECULA_ID ", "ids"), ("SPECULA_META ", "meta")):
                if marker in line:
                    require(case is not None, f"orphan {marker}")
                    case[key].append(json.loads(line.split(marker, 1)[1]))
    require(completed and case is None and cases, "incomplete guest execution")
    require(len({c["setup"]["name"] for c in cases}) == len(cases), "duplicate scenario name")
    manifests = [normalize(case, args.output, args.raw, names) for case in cases]
    coverage = collections.Counter()
    for m in manifests:
        coverage.update(m["coverage"])
    report = {"scenarios": len(manifests), "events": sum(m["events"] for m in manifests), "coverage": coverage,
              "uncovered": sorted(names - coverage.keys()), "concurrent_traces": sum(m["overlapping_pairs"] > 0 for m in manifests),
              "max_cross_thread_overlap_fraction": max(m["overlap_fraction"] for m in manifests),
              "twenty_percent_quality_met": any(m["overlap_fraction"] >= .2 and m["cross_cpu_overlapping_pairs"] > 0 for m in manifests)}
    write_json(args.raw / "coverage.json", report)
    print(json.dumps(report, indent=2))
    require(not report["uncovered"], "instrumented event coverage is incomplete")
    require(report["twenty_percent_quality_met"], "no trace meets the 20 percent cross-thread overlap requirement")


if __name__ == "__main__":
    main()
