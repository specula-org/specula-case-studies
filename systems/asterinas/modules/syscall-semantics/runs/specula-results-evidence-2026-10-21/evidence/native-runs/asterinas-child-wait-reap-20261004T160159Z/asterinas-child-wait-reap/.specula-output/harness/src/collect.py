#!/usr/bin/env python3
"""Decode observed records. This never executes a model or fills missing events."""
import argparse
from bisect import bisect_right
from collections import Counter, deque
import hashlib
import json
from pathlib import Path
from review_gate import check as check_review

EVENTS = """SysWaitBegin TryWaitChildrenLock TryWaitChildrenMatch TryWaitChildrenZombie
TryWaitChildrenRetain ReapZombieChildRemove ReapZombieChildPidRemove ReapZombieChildFinish
TryWaitChildrenUnlock DoWaitFound DoWaitNoMatch DoWaitNoHang DoWaitPending WaiterNewPair
SetSignalledWaker WaitQueueEnqueue PauseCheckCancellation WakerConsumeToken ParkCurrentCheck
ParkCurrentDequeue ParkCurrentResume ParkCurrentSpurious ClearSignalledWaker WaiterClose
SysWait4ReadStatus SysWaitidReadStatus SysWaitCopyout WaitStatusDrop SysWaitReturn
ProcessStoreExitCode ProcessPublishZombie ProcessEnqueueSignal WakeSignalledWakerNone
WakeSignalledWakerGet ProcessSignalLoopDone WakerWakeUp SchedulerUnparkTarget WakerWakeFinish
WaitQueueWakeAllCheck WaitQueueWakeAllPop WaitQueueWakeAllDone""".split()
ACTORS = {0: "none", 1: "w1", 2: "w2", 3: "child"}
PIN = "0c60537098f4c2949ad2d382aaf499de72263d76"
EVIDENCE_CLASS = "CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND"
CLAIM = (
    "An accepted TraceSearch.cfg witness shows that the observed per-event arguments and post-states "
    "are consistent with some model interleaving that respects each actor's local order and the "
    "recorded cross-actor interval constraints after widening by the sampled calibration bound. "
    "It does not establish the real global order, store-visibility timing, or a run-wide clock bound. "
    "A rejection is a candidate mismatch that must be re-examined against the clock limits before "
    "any model or kernel conclusion."
)
LABEL = dict(evidence_class=EVIDENCE_CLASS, claim=CLAIM)


def signed(n):
    return n - (1 << 64) if n >= 1 << 63 else n


def call(a, g):
    assert (a == 0 and g == 0) or (a in (1, 2) and g > 0), (a, g)
    return [] if a == 0 else [ACTORS[a], g]


def out(values):
    assert len(values) == 5
    return dict(zip(("pid", "uid", "signo", "siCode", "status"), map(signed, values)))


def queue(data):
    count, length, *pairs = data
    assert count == length and len(pairs) == length * 2, "truncated queue snapshot"
    entries = [call(*pairs[i:i+2]) for i in range(0, len(pairs), 2)]
    assert all(entries), "unregistered waker in fixture queue"
    return {"queue": entries, "queueCount": count}


def remaining(mask):
    assert 0 <= mask <= 3
    return [ACTORS[i+1] for i in range(2) if mask & (1 << i)]


def decode(actor, record, users):
    ident, start, end, a, generation, length, *p = record
    assert 1 <= ident <= len(EVENTS) and length == len(p)
    event = EVENTS[ident-1]
    key = call(a, generation)
    args = {"call": key}
    post = {}
    if ident == 1:
        api, pid, which, options, rusage, buffer, *initial = p
        assert api in (4, 247)
        request = {"api": "wait4" if api == 4 else "waitid", "nohang": bool(options & 1), "nowait": bool(options & 0x1000000)}
        args.update(request=request, pid=pid, which=which, options=options, rusage=rusage, buffer=buffer, initial=out(initial))
        post = dict(pc="lock", current=generation, **request, out=out(initial))
    elif ident == 2: post = dict(pc="match", childrenOwner=actor)
    elif ident == 3: post = dict(pc="zombie" if p[0] else "unlock", scan="matched" if p[0] else "absent", childPresent=bool(p[0]))
    elif ident == 4: post = dict(pc="retain" if p[0] else "unlock", scan="zombie" if p[0] else "live", acquired=bool(p[0]))
    elif ident == 5: post = dict(pc="unlock" if p[1] else "remove", selected=True, selectedPid=p[0], selectedPresent=True, retained=True)
    elif ident == 6: post = dict(pc="pidRemove", childPresent=bool(p[0]), claimed=True)
    elif ident == 7: post = dict(pc="cleanup", pidPresent=False)
    elif ident == 8: post = dict(pc="unlock")
    elif ident == 9: post = dict(pc="decide", childrenOwner="none")
    elif ident in (10, 11, 12):
        outcome = {10: "event", 11: "ECHILD", 12: "noevent"}[ident]
        post = dict(pc="clearSignal" if p[0] else ("read" if ident == 10 else "return"), outcome=outcome)
    elif ident == 13: post = dict(pc="cancel" if p[0] else "create")
    elif ident == 14: post = dict(pc="register", created=True, token=False, closed=False)
    elif ident == 15: post = dict(pc="enqueue", signalReg=key)
    elif ident == 16: post = dict(pc="lock", **queue(p))
    elif ident == 17: post = dict(pc="token", pendingUnblocked=bool(p[0]), timerActive=bool(p[1]))
    elif ident == 18: post = dict(pc="enqueue" if p[0] else "park", token=False, oldToken=bool(p[0]))
    elif ident == 19: post = dict(pc="token" if p[0] else "dequeue", rqHeld=not bool(p[0]), observedToken=bool(p[0]))
    elif ident == 20: post = dict(pc="parked", runnable=False, rqHeld=False)
    elif ident == 21: post = dict(pc="token", runnable=True)
    elif ident == 22: raise ValueError("spurious resume requires independent scheduler evidence")
    elif ident == 23: post = dict(pc="close", signalReg=[])
    elif ident == 24: post = dict(pc="read" if p[0] == 10 else "return", token=True, closed=True)
    elif ident in (25, 26):
        post = dict(pc="copy", readCode=p[0], selectedPid=p[1], retained=True)
        if ident == 26: post["uid"] = p[2]
    elif ident == 27: post = dict(pc="drop", out=out(p), outputWritten=True, retained=True)
    elif ident == 28: post = dict(pc="return", retained=False)
    elif ident == 29:
        user = users[(actor, generation)]
        assert user["start"] <= start <= end <= user["end"], "kernel/user clock inversion"
        end = user["end"]
        post = dict(pc="done", ret=signed(p[0]), libcRet=user["libcRet"], errno=user["errno"], out=user["out"])
    elif ident == 30:
        args["value"] = p[0] >> 8
        post = dict(exitPc="publish", exitValue=p[0] >> 8, storedCode=p[0])
    elif ident == 31: post = dict(exitPc="signalEnqueue", zombie=True)
    elif ident == 32: post = dict(exitPc="signalLoop", pendingSignal=True, remaining=remaining(p[0]))
    elif ident in (33, 34):
        args["thread"] = ACTORS[p[0]]
        post = dict(exitPc="signalLoop" if ident == 33 else "wake", remaining=remaining(p[1]))
        if ident == 34: post.update(signalHeld=ACTORS[p[0]], wakeTarget=key, wakeChannel="signal")
    elif ident == 35: post = dict(exitPc="queueCheck")
    elif ident == 36: post = dict(exitPc="wakeFinish" if p[0] else "unpark", token=True, oldToken=bool(p[0]))
    elif ident == 37: post = dict(exitPc="wakeFinish", runnable=True, rqHeld=False)
    elif ident == 38: post = dict(exitPc="signalLoop" if p[0] == 1 else "queuePop", signalHeld="none", wakeTarget=[], wakeChannel="none")
    elif ident == 39: post = dict(exitPc="done" if p[0] == 0 else "queuePop", queueCount=p[0])
    elif ident == 40: post = dict(exitPc="wake", **queue(p), wakeTarget=key, wakeChannel="queue")
    elif ident == 41: post = dict(exitPc="done", queueCount=p[0])
    assert start <= end
    return dict(tag="trace", actor=actor, event=event, start=start, end=end, args=args, post=post)


# This is an admission threshold for sampled consistency, not a drift guarantee.
CLOCK_SAMPLES = 64
MAX_OFFSET_BOUND_CYCLES = 100_000


def require(condition, message):
    if not condition:
        raise ValueError(message)


def calibration(lines, meta):
    require(meta.get("clock") == "lfence-rdtsc-lfence-v4", "missing v4 ordered clock")
    require(meta.get("clock_samples_per_phase") == CLOCK_SAMPLES and
            meta.get("clock_phases") == ["pre", "post"], "missing pre/post calibration")
    cpus = meta.get("cpu_affinity", [])
    require(len(cpus) == 2 and all(type(c) is int and c >= 0 for c in cpus) and
            cpus[0] != cpus[1], "calibration needs two distinct pinned CPUs")
    actor_cpu = {"w1": cpus[0], "w2": cpus[1], "child": cpus[1]}
    identities = {}
    samples = {"pre": [], "post": []}
    for line in lines:
        if line.startswith("WR_CLOCK_CPU "):
            info = json.loads(line[len("WR_CLOCK_CPU "):])
            actor = info["actor"]
            require(actor in actor_cpu and actor not in identities, "unexpected or duplicate clock CPU")
            require(info["cpu"] == actor_cpu[actor], "uncalibrated actor CPU")
            require(info["vendor"] == "GenuineIntel", "unreviewed LFENCE execution semantics")
            require(info["max_extended"] >= 0x80000007 and info["invariant_edx"] & (1 << 8),
                    "invariant TSC CPUID.80000007H:EDX[8] is absent")
            require(info["features_edx"] & (1 << 4) and info["features_edx"] & (1 << 26),
                    "missing TSC or SSE2/LFENCE")
            identities[actor] = info
        elif line.startswith("WR_CLOCK "):
            fields = line.split()
            require(len(fields) == 7 and fields[1] in samples, "malformed calibration sample")
            phase, index = fields[1], int(fields[2])
            require(index == len(samples[phase]), "missing, duplicate or reordered calibration sample")
            row = list(map(int, fields[3:]))
            require(all(0 <= v < 1 << 64 for v in row), "invalid TSC value")
            require(row[0] <= row[3] and row[1] <= row[2], "local calibration clock inversion")
            if samples[phase]:
                prior = samples[phase][-1]
                require(prior[3] <= row[0] and prior[2] <= row[1], "local calibration clock regression")
            samples[phase].append(row)
    require(set(identities) == set(actor_cpu), "missing guest/control per-actor CPUID evidence")
    ranges = {}
    for phase, rows in samples.items():
        require(len(rows) == CLOCK_SAMPLES, "missing pre/post calibration samples")
        # For B(t) = A(t) + delta throughout an epoch, causality gives
        # b_send - a_receive <= delta <= b_receive - a_send.
        lower = max(b1 - a1 for a0, b0, b1, a1 in rows)
        upper = min(b0 - a0 for a0, b0, b1, a1 in rows)
        require(lower <= upper, f"{phase}: no constant offset fits the samples")
        ranges[phase] = {"lower": lower, "upper": upper}
    require(max(r["lower"] for r in ranges.values()) <= min(r["upper"] for r in ranges.values()),
            "pre/post samples contradict a constant offset")
    bound = max(abs(v) for r in ranges.values() for v in r.values())
    require(bound <= MAX_OFFSET_BOUND_CYCLES,
            f"sampled offset bound {bound} exceeds {MAX_OFFSET_BOUND_CYCLES} cycles")
    windows = {"w1": [samples["pre"][-1][3], samples["post"][0][0]],
               "w2": [samples["pre"][-1][2], samples["post"][0][1]],
               "child": [samples["pre"][-1][2], samples["post"][0][1]]}
    require(all(lo <= hi for lo, hi in windows.values()), "pre/post clock regression")
    return dict(status="SAMPLED_ONLY", reference_cpu=cpus[0], target_cpu=cpus[1],
                actor_cpu=actor_cpu, cpuid=identities, samples=samples,
                offset_ranges_cycles=ranges, sampled_abs_bound_cycles=bound,
                threshold_cycles=MAX_OFFSET_BOUND_CYCLES, local_windows=windows,
                run_wide_bound_cycles=None,
                assumption="One constant B-minus-A offset during each calibration epoch; not established for the run")


def read_records(log, linux_control):
    lines = log.read_text(errors="strict").replace("\r", "").splitlines()
    assert lines.count("WR_COMPLETE") == 1, "missing or duplicate fixture completion"
    metadata = [json.loads(s[8:]) for s in lines if s.startswith("WR_META ")]
    assert len(metadata) == 1
    meta = metadata[0]
    clock = calibration(lines, meta)
    users = {}
    for s in lines:
        if s.startswith("WR_USER "):
            u = json.loads(s[8:]); k = (u["actor"], u["generation"])
            assert k not in users, "duplicate user call"
            users[k] = u
    streams, headers = {a: [] for a in ("w1", "w2", "child")}, {}
    for s in lines:
        if s.startswith("WR_STREAM "):
            a, count, drops = map(int, s.split()[1:])
            assert a not in headers and drops == 0, "duplicate stream header or dropped events"
            headers[a] = count
        elif s.startswith("WR_RAW "):
            a, *words = map(int, s.split()[1:])
            streams[ACTORS[a]].append(decode(ACTORS[a], words, users))
    if linux_control:
        require(not headers and not any(streams.values()), "Linux control contains kernel trace records")
        require(meta["kernel"].startswith("Linux "), "control is not identified as Linux")
    else:
        assert set(headers) == {1, 2, 3}, "missing or unexpected stream header"
        for a, events in streams.items():
            assert len(events) == headers[{"w1": 1, "w2": 2, "child": 3}[a]], "stream count mismatch"
            assert all(x["end"] <= y["start"] for x, y in zip(events, events[1:])), f"{a}: local interval overlap"
        assert sum(e["event"] == "SysWaitReturn" for es in streams.values() for e in es) == len(users), "return-count mismatch"
    all_events = [e for es in streams.values() for e in es]
    require(bool(users), "no user calls recorded")
    for e in all_events + list(users.values()):
        lo, hi = clock["local_windows"][e["actor"]]
        require(lo <= e["start"] <= e["end"] <= hi, "event outside local pre/post calibration window")
    return lines, meta, clock, users, streams


def cpu_evidence(lines, meta, log, linux_control):
    prefix = "WR_CONTROL_NPROC " if linux_control else "WR_GUEST_NPROC "
    counts = [int(s[len(prefix):]) for s in lines if s.startswith(prefix)]
    require(len(counts) == 1 and counts[0] >= 2, "missing or invalid invocation nproc evidence")
    result = dict(nproc=counts[0], scope="linux-control" if linux_control else "asterinas-guest",
                  fixture_smp=meta["smp"])
    if not linux_control:
        path = log.with_suffix(".command.json")
        command = json.loads(path.read_text())
        require(command.count("-smp") == 1, "missing or duplicate boot -smp")
        smp = int(command[command.index("-smp") + 1])
        require(smp == counts[0] == meta["smp"], "guest nproc, boot -smp and fixture CPU counts disagree")
        require(all(0 <= cpu < smp for cpu in meta["cpu_affinity"]), "affinity outside guest CPU count")
        result.update(boot_smp=smp, boot_command=command,
                      boot_command_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    return result


def encode_intervals(streams, clock):
    """Encode exactly the widened cross-actor comparisons, or refuse."""
    nodes = []
    offsets = {}
    for actor, events in streams.items():
        offsets[actor] = len(nodes)
        nodes.extend((actor, i, endpoint) for i in range(len(events)) for endpoint in ("start", "end"))
    graph = [[] for _ in nodes]
    reverse = [[] for _ in nodes]

    def edge(left, right, distance):
        # Every edge means rank[right] >= rank[left] + distance.
        graph[left].append((right, distance))
        reverse[right].append(left)

    starts = {a: [e["start"] for e in es] for a, es in streams.items()}
    bound = clock["sampled_abs_bound_cycles"]
    for actor, events in streams.items():
        for i, event in enumerate(events):
            start = offsets[actor] + 2 * i
            end = start + 1
            edge(start, end, 0)
            if i + 1 < len(events):
                edge(end, end + 1, 0)
            for other, other_events in streams.items():
                if other == actor:
                    continue
                margin = 2 * bound if clock["actor_cpu"][actor] != clock["actor_cpu"][other] else 0
                split = bisect_right(starts[other], event["end"] + margin)
                # Local monotonicity makes these two boundary constraints
                # equivalent to comparing this end with every other start.
                if split < len(other_events):
                    edge(end, offsets[other] + 2 * split, 1)
                if split:
                    edge(offsets[other] + 2 * (split - 1), end, 0)

    # Zero-distance cycles mean equality. A cycle containing a strict edge
    # proves that no scalar intervals satisfy both required relations.
    seen, order = set(), []
    for root in range(len(nodes)):
        stack = [(root, False)]
        while stack:
            node, finished = stack.pop()
            if finished:
                order.append(node)
            elif node not in seen:
                seen.add(node)
                stack.append((node, True))
                stack.extend((n, False) for n, _ in graph[node] if n not in seen)
    component = [-1] * len(nodes)
    count = 0
    for root in reversed(order):
        if component[root] != -1:
            continue
        stack = [root]
        component[root] = count
        while stack:
            for node in reverse[stack.pop()]:
                if component[node] == -1:
                    component[node] = count
                    stack.append(node)
        count += 1
    dag, indegree = [[] for _ in range(count)], [0] * count
    for left, edges in enumerate(graph):
        for right, distance in edges:
            a, b = component[left], component[right]
            if a == b:
                require(distance == 0,
                        f"UNREPRESENTABLE_LOCAL_ORDER: strict {nodes[left]} < {nodes[right]} "
                        "lies in a constraint cycle; no exact TraceShapeOK encoding exists")
            else:
                dag[a].append((b, distance))
                indegree[b] += 1
    ready = deque(i for i, degree in enumerate(indegree) if degree == 0)
    ranks = [0] * count
    while ready:
        node = ready.popleft()
        for other, distance in dag[node]:
            ranks[other] = max(ranks[other], ranks[node] + distance)
            indegree[other] -= 1
            if indegree[other] == 0:
                ready.append(other)
    encoded = {a: [dict(e, start=ranks[component[offsets[a] + 2 * i]],
                           end=ranks[component[offsets[a] + 2 * i + 1]])
                   for i, e in enumerate(es)] for a, es in streams.items()}
    # Audit the complete relation, including absent edges and touching ends.
    # This checks the encoding itself without consulting any model state.
    for actor, events in streams.items():
        local = encoded[actor]
        require(all(e["start"] <= e["end"] for e in local) and
                all(x["end"] <= y["start"] for x, y in zip(local, local[1:])), "encoding broke local order")
        for other, other_events in streams.items():
            if actor == other:
                continue
            margin = 2 * bound if clock["actor_cpu"][actor] != clock["actor_cpu"][other] else 0
            for i, event in enumerate(events):
                for j, following in enumerate(other_events):
                    require((event["end"] + margin < following["start"]) ==
                            (local[i]["end"] < encoded[other][j]["start"]),
                            "encoding changed a widened cross-actor comparison")
    return encoded


def write_json(path, data, compact=False):
    with path.open("x") as stream:
        stream.write(json.dumps(data, **({"separators": (",", ":")} if compact else {"indent": 2})) + "\n")


def collect(log, output, consistency=False, linux_control=False):
    check_review(consistency=consistency)
    require(not (consistency and linux_control), "Linux controls cannot emit kernel TraceData")
    require(output.suffix == (".ndjson" if consistency else ".json"), "incorrect output suffix for collection mode")
    diagnostic = output.with_suffix(".diagnostic.json") if consistency else output
    sidecar = output.with_suffix(".collection.json") if consistency else None
    raw_dir = diagnostic.parent / (diagnostic.stem + "-events")
    for path in (output, diagnostic, sidecar, raw_dir):
        require(path is None or not path.exists(), f"refusing to overwrite collection evidence: {path}")
    output.parent.mkdir(parents=True, exist_ok=True)
    report = dict(LABEL, schema="asterinas-wait-reap-diagnostic-v5", source=PIN,
                  environment="linux-control" if linux_control else "asterinas-guest",
                  input_path=str(log.resolve()),
                  input_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),
                  review_gate_sha256=hashlib.sha256((Path(__file__).resolve().parent.parent / "review-gate.json").read_bytes()).hexdigest(),
                  acceptance="INELIGIBLE", grouped_trace="NOT_EMITTED",
                  ordering="LOCAL_STREAM_ORDER_ONLY",
                  blockers=["plain-store global visibility is not bracketed",
                            "cross-CPU offset/drift has no run-wide guarantee"])
    grouped = None
    try:
        lines, meta, clock, users, streams = read_records(log, linux_control)
        report.update(metadata=meta, clock=clock, user_calls=list(users.values()),
                      events=sum(map(len, streams.values())),
                      coverage=dict(Counter(e["event"] for es in streams.values() for e in es)))
        raw_dir.mkdir(exist_ok=False)
        for actor, events in streams.items():
            records = [dict(tag="diagnostic", actor=e["actor"], event=e["event"],
                            local_start_tsc=e["start"], local_end_tsc=e["end"],
                            args=e["args"], post=e["post"]) for e in events]
            write_json(raw_dir / f"{actor}.json", dict(LABEL, acceptance="INELIGIBLE", events=records))
        report["event_files"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(raw_dir.iterdir())}
        report["cpu_count"] = cpu_evidence(lines, meta, log, linux_control)
        if consistency:
            encoded = encode_intervals(streams, clock)
            grouped = {k: meta[k] for k in ("child_pid", "child_uid", "exit_value", "smp", "concurrent", "buffers", "sigchld", "sa_nocldwait", "sigchld_blocked", "valid_buffers", "rusage_null")}
            grouped.update(LABEL, schema="asterinas-wait-reap-timebox-v1", source=PIN,
                           waiters=["w1", "w2"], traces=encoded, cpu_count=report["cpu_count"],
                           interval_encoding="exact-cross-actor-constraints-v5",
                           sampled_abs_bound_cycles=clock["sampled_abs_bound_cycles"],
                           run_wide_clock_bound="UNESTABLISHED", store_visibility_timing="UNESTABLISHED",
                           cross_cpu_endpoint_widening_cycles=clock["sampled_abs_bound_cycles"],
                           same_cpu_endpoint_widening_cycles=0, validation="NOT_RUN",
                           input_sha256=report["input_sha256"], review_gate_sha256=report["review_gate_sha256"])
            report["grouped_trace"] = "EMITTED"
    except (AssertionError, ValueError, KeyError, IndexError, TypeError, OSError) as error:
        grouped = None
        report.update(grouped_trace="REFUSED" if consistency else "NOT_EMITTED",
                      refusal=f"{type(error).__name__}: {error}")
    write_json(diagnostic, report)
    if sidecar:
        manifest = dict(report, schema="asterinas-wait-reap-collection-v5",
                        diagnostic_file=diagnostic.name,
                        diagnostic_sha256=hashlib.sha256(diagnostic.read_bytes()).hexdigest(),
                        validation="NOT_RUN", acceptance="NOT_VALIDATED" if grouped else "INELIGIBLE")
        if grouped:
            write_json(output, grouped, compact=True)
            manifest.update(output_file=output.name, output_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
                            interval_encoding=grouped["interval_encoding"], ordering="LOCAL_ORDER_AND_WIDENED_CROSS_ACTOR_CONSTRAINTS",
                            cross_cpu_endpoint_widening_cycles=clock["sampled_abs_bound_cycles"],
                            same_cpu_endpoint_widening_cycles=0)
        write_json(sidecar, manifest)
    print(json.dumps(dict(LABEL, report=str(diagnostic), grouped_trace=report["grouped_trace"],
                          refusal=report.get("refusal")), indent=2))
    if "refusal" in report:
        raise SystemExit(65)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--outcome", "--diagnostic", dest="outcome", action="store_true", help="write syscall outcomes without implementation records")
    mode.add_argument("--clock-diagnostic", action="store_true", help="write legacy clock diagnostics under consistency approval")
    mode.add_argument("--consistency", action="store_true", help="also emit labelled sampled-bound TraceData")
    p.add_argument("--linux-control", action="store_true", help="expect user calls without kernel records")
    p.add_argument("--case", help="cases.tsv name, required for outcome mode")
    p.add_argument("--run-exit-code", type=int, default=0, help="fixture or boot command exit code")
    p.add_argument("log", type=Path)
    p.add_argument("output", type=Path)
    args = p.parse_args()
    if args.outcome:
        if not args.case:
            p.error("outcome mode requires --case")
        from collect_outcome import collect as collect_outcome
        collect_outcome(args.log, args.output, args.case, args.linux_control, args.run_exit_code)
    else:
        if args.case or args.run_exit_code:
            p.error("case and run-exit-code belong to outcome mode")
        collect(args.log, args.output, args.consistency, args.linux_control)
