#!/usr/bin/env python3
"""Compare syscall outcomes with the pinned Linux source contract, without clocks."""
import errno
import hashlib
import json
from pathlib import Path
import struct

from review_gate import check as check_review

HERE = Path(__file__).resolve().parent.parent
SIGINFO = ("si_signo", "si_errno", "si_code", "si_pid", "si_uid", "si_status")
NOHANG, STOPPED, EXITED, NOWAIT = 1, 2, 4, 0x01000000


def require(condition, message):
    if not condition:
        raise ValueError(message)


def case_named(name):
    rows = [line.split() for line in (HERE / "cases.tsv").read_text().splitlines()
            if line.strip() and not line.startswith("#")]
    matches = [row for row in rows if row[0] == name]
    require(len(matches) == 1 and len(matches[0]) == 8, "unknown or ambiguous case")
    _, scenario, value, delay, pair, readiness, wr_ids, modes = matches[0]
    return dict(name=name, scenario=scenario, exit_value=int(value), exit_delay_us=int(delay),
                pair=pair, readiness=readiness, wr_ids=wr_ids.split(","), modes=modes)


def call_plan(case):
    """The plan fixes API, flags, buffer and allowed result before reading the log."""
    result = []

    def add(purpose, api, options, oracle, actor="w1", buffer=None):
        result.append(dict(actor=actor, call_index=1 + sum(c["actor"] == actor for c in result),
                           purpose=purpose, api=api, options=options, oracle=oracle,
                           buffer=buffer or ("status-sentinel" if api == "wait4" else "siginfo-zero")))

    scenario = case["scenario"]
    ready = case["readiness"] == "ready"
    if ready:
        add("establish-zombie", "waitid", EXITED | NOWAIT, "event")
    if scenario == "compete":
        for actor, code in zip(("w1", "w2"), case["pair"]):
            add("consume", "wait4" if code == "4" else "waitid", 0 if code == "4" else EXITED,
                "event-or-echild", actor)
    elif scenario == "overlap":
        add("observer", "waitid", EXITED | NOWAIT, "event-or-echild")
        api = "wait4" if case["pair"][1] == "4" else "waitid"
        add("consume", api, 0 if api == "wait4" else EXITED, "event", "w2")
    elif scenario in ("cf4", "cfid", "cfnowait"):
        api = "wait4" if scenario == "cf4" else "waitid"
        options = 0 if api == "wait4" else EXITED
        add("fault", api, options | (NOWAIT if scenario == "cfnowait" else 0), "efault", buffer="PROT_NONE")
        add("after-fault", api, options | NOHANG, "event" if scenario == "cfnowait" else "echild")
    elif scenario == "lx":
        # wait_consider_task returns the zombie helper's zero without clearing
        # notask_error, so __do_wait returns ECHILD for this single-thread child.
        add("without-wexited", "waitid", STOPPED | NOHANG, "echild")
        add("with-wexited", "waitid", EXITED | NOHANG, "event")
    else:
        require(scenario in ("nohang", "observe4", "observeid", "sq-zero", "sq-poison"), "unsupported case scenario")
        if scenario.startswith("sq-"):
            add("live-siginfo", "waitid", EXITED | NOHANG, "zero",
                buffer="siginfo-zero" if scenario == "sq-zero" else "siginfo-poison")
        elif scenario == "nohang":
            add("live-wait4", "wait4", NOHANG, "unchanged")
            add("live-waitid", "waitid", EXITED | NOHANG, "zero")
        if scenario.startswith("observe"):
            add("observe-1", "waitid", EXITED | NOWAIT, "event")
            add("observe-2", "waitid", EXITED | NOWAIT | NOHANG, "event")
        api = "waitid" if scenario == "observeid" else "wait4"
        add("consume", api, EXITED if api == "waitid" else 0, "event")
    add("post-waitid", "waitid", EXITED | NOWAIT, "echild")
    add("post-wait4", "wait4", NOHANG, "echild")
    return result


def expected_results(plan, meta):
    event = dict(return_value=meta.get("child_pid", "CHILD_PID") if plan["api"] == "wait4" else 0,
                 errno=0, fields={"status": meta["exit_value"] << 8} if plan["api"] == "wait4" else
                 dict(si_signo=17, si_errno=0, si_code=1, si_pid=meta.get("child_pid", "CHILD_PID"),
                      si_uid=meta.get("child_uid", "CHILD_UID"), si_status=meta["exit_value"]))
    echild = dict(return_value=-1, errno=errno.ECHILD, fields="NOT_COMPARED_ON_ERROR")
    return {
        "event": [event], "echild": [echild], "event-or-echild": [event, echild],
        "efault": [dict(return_value=-1, errno=errno.EFAULT, fields="INACCESSIBLE")],
        "zero": [dict(return_value=0, errno=0, fields=dict.fromkeys(SIGINFO, 0))],
        "unchanged": [dict(return_value=0, errno=0, fields={"status": -999}, bytes="UNCHANGED")],
    }[plan["oracle"]]


def matches(call, expected):
    if call["return"] != expected["return_value"] or call["errno"] != expected["errno"]:
        return False
    if isinstance(expected["fields"], dict) and call["after"]["fields"] != expected["fields"]:
        return False
    return expected.get("bytes") != "UNCHANGED" or call["after"]["bytes"] == call["before"]["bytes"]


def validate_meta(meta, case, linux_control):
    require(set(meta) == {"mode", "scenario", "pair", "child_pid", "child_uid", "exit_value", "exit_delay_us",
                         "already_exited", "online_cpus", "affinity_count", "selected_cpus", "sigchld",
                         "sa_nocldwait", "sigchld_blocked", "kernel_recorder", "observer_delay_control",
                         "kernel", "libc", "cpu_identity"}, "invalid outcome metadata fields")
    require(meta["mode"] == "outcome" and meta["kernel_recorder"] == "NOT_ARMED" and
            meta["observer_delay_control"] == "INACTIVE", "outcome mode or recorder state mismatch")
    require(all(meta[k] == case[k] for k in ("scenario", "pair", "exit_value", "exit_delay_us")) and
            meta["already_exited"] == (case["readiness"] == "ready"), "case arguments mismatch")
    require(all(type(meta[k]) is int and meta[k] >= 0 for k in
                ("child_pid", "child_uid", "exit_value", "exit_delay_us", "online_cpus", "affinity_count")) and
            meta["child_pid"] > 0, "invalid fixture identity")
    cpus = meta["selected_cpus"]
    require(meta["affinity_count"] == 2 and isinstance(cpus, list) and len(cpus) == 2 and
            all(type(c) is int and c >= 0 for c in cpus) and cpus[0] != cpus[1], "fixture requires two eligible CPUs")
    require(meta["sigchld"] == "SIG_DFL" and meta["sa_nocldwait"] is False and
            meta["sigchld_blocked"] is True, "signal contract mismatch")
    # The pinned Asterinas UTS namespace also reports Linux for libc compatibility.
    # The guest identity comes from the runner and its boot records.
    require(isinstance(meta["kernel"], str) and meta["kernel"].startswith("Linux ") and
            isinstance(meta["libc"], str) and meta["libc"].startswith("glibc "), "system identity mismatch")
    cpu = meta["cpu_identity"]
    require(set(cpu) == {"cpu", "vendor", "max_extended", "features_edx", "invariant_edx",
                         "hypervisor_present", "hypervisor_vendor"}, "invalid CPUID fields")
    # cpu_identity.cpu is the CPU w1 actually ran on when CPUID was read. Placement is recorded,
    # not required, because the pinned Asterinas cannot migrate on sched_setaffinity.
    require(type(cpu["cpu"]) is int and cpu["cpu"] >= 0 and all(type(cpu[k]) is int and 0 <= cpu[k] < 2**32
            for k in ("max_extended", "features_edx", "invariant_edx")) and
            all(isinstance(cpu[k], str) and len(cpu[k]) <= 12 for k in ("vendor", "hypervisor_vendor")) and
            type(cpu["hypervisor_present"]) is bool, "invalid CPUID identity")


def validate_call(call, meta):
    require(set(call) == {"actor", "call_index", "purpose", "api", "syscall_number", "options", "pid", "idtype",
                         "rusage", "buffer", "return", "errno", "before", "after"}, "invalid syscall fields")
    require(call["actor"] in ("w1", "w2") and call["api"] in ("wait4", "waitid") and
            isinstance(call["purpose"], str), "invalid syscall identity")
    require(all(type(call[k]) is int for k in ("call_index", "syscall_number", "options", "pid", "return", "errno")) and
            call["call_index"] > 0 and call["errno"] >= 0, "invalid syscall numbers")
    wait4 = call["api"] == "wait4"
    require(call["syscall_number"] == (61 if wait4 else 247) and call["pid"] == meta["child_pid"] and
            call["idtype"] == (None if wait4 else "P_PID") and call["rusage"] is None, "syscall argument mismatch")
    require(call["buffer"] in ("PROT_NONE", "status-sentinel") if wait4 else
            call["buffer"] in ("PROT_NONE", "siginfo-zero", "siginfo-poison"), "invalid buffer kind")
    for phase in ("before", "after"):
        output = call[phase]
        require(set(output) == {"accessible", "fields", "bytes"}, "invalid output fields")
        if call["buffer"] == "PROT_NONE":
            require(output == dict(accessible=False, fields=None, bytes=None), "inaccessible output was read")
            continue
        require(output["accessible"] is True and isinstance(output["bytes"], str) and
                len(output["bytes"]) == (8 if wait4 else 256), "missing output bytes")
        raw = bytes.fromhex(output["bytes"])
        require(len(raw) == (4 if wait4 else 128), "invalid output bytes")
        if wait4:
            fields = dict(status=struct.unpack("<i", raw)[0])
        else:
            fields = dict(zip(SIGINFO, struct.unpack("<iii4xiIi", raw[:28])))
        require(output["fields"] == fields, "decoded output fields disagree with bytes")
    if call["buffer"] != "PROT_NONE":
        before = bytes.fromhex(call["before"]["bytes"])
        require(before == (struct.pack("<i", -999) if wait4 else
                           bytes([0xa5 if call["buffer"] == "siginfo-poison" else 0]) * 128), "incorrect initial sentinel")


def cpu_counts(lines, meta, log, linux_control):
    prefix = "WR_CONTROL_NPROC " if linux_control else "WR_GUEST_NPROC "
    counts = [int(line[len(prefix):]) for line in lines if line.startswith(prefix)]
    require(counts == [2], "missing, duplicate or non-SMP=2 CPU evidence")
    result = dict(measured_nproc=counts[0], eligible_cpus=meta["affinity_count"],
                  online_cpus=meta["online_cpus"], selected_cpus=meta["selected_cpus"],
                  scope="two-CPU Linux control affinity" if linux_control else "Asterinas guest SMP")
    if not linux_control:
        command = json.loads(log.with_suffix(".command.json").read_text())
        require(command.count("-smp") == 1 and command[command.index("-smp") + 1] == "2" and
                meta["online_cpus"] == 2 and meta["selected_cpus"] == [0, 1], "guest CPU counts disagree")
        boot = json.loads(log.with_suffix(".outcome.json").read_text())
        require(boot["fixture_complete"] is True and boot["guest_nproc"] == boot["boot_smp"] == 2 and
                boot["qemu_returncode"] == 0 and boot["termination"] == "QMP quit after fixture completion", "incomplete guest boot")
        result["boot_smp"] = 2
    return result


def collect(log, output, case_name, linux_control=False, run_exit_code=0):
    check_review(outcome=True)
    require(output.name.endswith(".outcome.json") and not output.exists(), "use a new .outcome.json output")
    # Boot supervision uses the same suffix beside the log, so collection must use
    # a separate directory to preserve both records.
    require(output.resolve() != log.with_suffix(".outcome.json").resolve(), "output would overwrite boot supervision")
    case = case_named(case_name)
    plan = call_plan(case)
    report = dict(schema="asterinas-wait-reap-outcomes-v6", mode="outcome", case=case,
                  evidence_class="OUTCOME_ONLY_NO_IMPLEMENTATION_TRACE", implementation_trace="NONE",
                  trace_validation="BLOCKED_ENVIRONMENT",
                  trace_validation_reason=dict(reason="AMD Ryzen 9 9950X KVM guest with kvm-clock and non-invariant TSC; the approved method requires GenuineIntel and invariant TSC.",
                      basis="First admitted v5 Linux control, reported 2026-10-10",
                      observed_admission_cpuid=dict(actor=3, cpu=1, vendor="AuthenticAMD", max_extended="80000022",
                                                    features_edx="178bfbff", invariant_edx="0")),
                  environment="linux-control" if linux_control else "asterinas-guest",
                  source="0c60537098f4c2949ad2d382aaf499de72263d76",
                  linux_oracle=dict(version="v6.16.5", commit="4645fefac0b24d509b962c096b0327e87f34b1d2",
                      contract="wait-reap/contracts.md", anchors="kernel/exit.c:1167-1179,1181-1191,1485-1494,1660-1694,1800-1827,1841-1873"),
                  raw_log=dict(path=str(log.resolve()), evidence_class="NON_TRACE_DIAGNOSTIC_MATERIAL"),
                  review_gate_sha256=hashlib.sha256((HERE / "review-gate.json").read_bytes()).hexdigest(),
                  run_exit_code=run_exit_code, fixture_complete=False, cpu_count=None, no_hang="inconclusive",
                  comparison="inconclusive", bug_classification="NOT_ASSESSED", calls=[], problems=[])
    meta, calls = None, {}
    stage = "reading the raw log"
    try:
        payload = log.read_bytes()
        report["raw_log"]["sha256"] = hashlib.sha256(payload).hexdigest()
        # A timeout can cut the serial log mid-line, even mid-character. Exclude the unterminated
        # tail before decoding so that completed records before it survive, and keep the run
        # inconclusive.
        complete = payload
        if payload and not payload.endswith((b"\n", b"\r")):
            complete = payload[:max(payload.rfind(b"\n"), payload.rfind(b"\r")) + 1]
            report["problems"].append("The truncated final log line was excluded from the outcome transport. The run is incomplete.")
        lines = complete.decode().replace("\r", "").splitlines()
        # Only these allowlisted JSON records can enter the report. Trace
        # transports are rejected and never copied, even into a failure message.
        stage = "checking the outcome transport"
        allowed = ("WR_OUTCOME_META ", "WR_OUTCOME_CALL ", "WR_OUTCOME_PLACEMENT", "WR_CONTROL_NPROC ", "WR_GUEST_NPROC ")
        markers = {"WR_OUTCOME_COMPLETE", "WR_OUTCOME_SETUP_FAILED"}
        require(all(not line.startswith("WR_") or line in markers or line.startswith(allowed) for line in lines),
                "unexpected recorder or clock transport in outcome log")
        stage = "checking fixture metadata"
        metadata = [json.loads(line[len("WR_OUTCOME_META "):]) for line in lines if line.startswith("WR_OUTCOME_META ")]
        require(len(metadata) == 1, "missing or duplicate outcome metadata")
        candidate = metadata[0]
        validate_meta(candidate, case, linux_control)
        meta = candidate
        report["metadata"] = meta
        stage = "checking syscall records"
        for line in lines:
            if not line.startswith("WR_OUTCOME_CALL "):
                continue
            call = json.loads(line[len("WR_OUTCOME_CALL "):])
            validate_call(call, meta)
            key = (call["actor"], call["call_index"])
            require(key not in calls and key[1] == 1 + sum(k[0] == key[0] for k in calls), "duplicate or missing call index")
            calls[key] = call
        stage = "checking actor placement"
        # Placement is recorded, not required: Asterinas cannot migrate on sched_setaffinity.
        # It is checked after the syscall records so that completed calls survive a missing or
        # malformed placement record. Incomplete placement still blocks overall success.
        # The transport stage admits any WR_OUTCOME_PLACEMENT line, so a malformed one fails here,
        # after the syscall records were kept.
        raw_placement = [line for line in lines if line.startswith("WR_OUTCOME_PLACEMENT")]
        require(all(line.startswith("WR_OUTCOME_PLACEMENT ") for line in raw_placement), "malformed placement record")
        placement = [json.loads(line[len("WR_OUTCOME_PLACEMENT "):]) for line in raw_placement]
        selected = meta["selected_cpus"]
        requested = {"w1": selected[0], "child": selected[1]}
        if meta["scenario"] in ("compete", "overlap"):
            requested["w2"] = selected[1]
        require(all(isinstance(p, dict) and set(p) == {"actor", "requested_cpu", "actual_cpu"} and
                    p["actor"] in requested and type(p["requested_cpu"]) is int and type(p["actual_cpu"]) is int and
                    p["actual_cpu"] >= 0 and p["requested_cpu"] == requested[p["actor"]] for p in placement) and
                sorted(p["actor"] for p in placement) == sorted(requested), "malformed or missing placement record")
        report["placement"] = placement
        actual = {p["actor"]: p["actual_cpu"] for p in placement}
        report["actors_on_distinct_cpus"] = actual["w1"] != actual["w2"] if "w2" in actual else None
        stage = "checking CPU and boot evidence"
        report["cpu_count"] = cpu_counts(lines, meta, log, linux_control)
        report["fixture_complete"] = lines.count("WR_OUTCOME_COMPLETE") == 1
        stage = "checking fixture completion"
        require(report["fixture_complete"] and run_exit_code == 0 and "WR_OUTCOME_SETUP_FAILED" not in lines,
                "fixture incomplete or execution limit reached")
        require(set(calls) == {(p["actor"], p["call_index"]) for p in plan}, "missing or unexpected syscall results")
    except (ValueError, KeyError, TypeError, IndexError, AttributeError, OSError, struct.error) as error:
        report["problems"].append(f"Evidence incomplete at {stage} ({type(error).__name__}); inspect the non-trace diagnostic log.")

    known = meta or dict(exit_value=case["exit_value"])
    setup_ok = True
    for p in plan:
        call = calls.get((p["actor"], p["call_index"]))
        expected = expected_results(p, known)
        arguments_ok = call is not None and all(call[k] == p[k] for k in ("purpose", "api", "options", "buffer"))
        comparison = "inconclusive"
        if arguments_ok and setup_ok:
            comparison = "match" if any(matches(call, e) for e in expected) else "mismatch"
        elif call is not None and not arguments_ok:
            report["problems"].append("Observed call arguments differ from the case plan.")
        if p["purpose"] == "establish-zombie":
            setup_ok = comparison == "match"
        report["calls"].append(dict(planned_call=p, observed=call, expected_linux_source=expected, comparison=comparison))
    history = dict(expected="Every planned call completes; post-consumption waits return ECHILD.", comparison="inconclusive")
    if not report["problems"] and setup_ok:
        report["no_hang"] = "match"
        comparison = "match" if all(c["comparison"] == "match" for c in report["calls"]) else "mismatch"
        if case["scenario"] == "compete":
            consumers = [c for c in report["calls"] if c["planned_call"]["purpose"] == "consume"]
            successes = sum(matches(c["observed"], c["expected_linux_source"][0]) for c in consumers)
            losers = sum(matches(c["observed"], c["expected_linux_source"][1]) for c in consumers)
            history["expected"] = "Exactly one consumer obtains the exit status, the other gets ECHILD, and both complete."
            if (successes, losers) != (1, 1):
                comparison = "mismatch"
        history["comparison"] = comparison
        report["comparison"] = comparison
    report["history"] = history
    report["coverage"] = {wr: dict(outcome_comparison=report["comparison"],
        internal_window="NOT_ESTABLISHED_OPPORTUNISTIC" if wr in ("WR-08", "WR-09", "WR-10") else "NOT_ASSESSED")
        for wr in case["wr_ids"]}
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x") as stream:
        stream.write(json.dumps(report, indent=2) + "\n")
    print(json.dumps(dict(output=str(output), comparison=report["comparison"], trace_validation=report["trace_validation"])))
