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
"""Strict input checks before Trace.tla, whose JSON reader otherwise filters records."""

import argparse
import collections
import hashlib
import json
import re
import time
from pathlib import Path


class TraceInputError(ValueError):
    pass


def require(ok, message):
    if not ok:
        raise TraceInputError(message)


def keys(value, expected, where):
    require(isinstance(value, dict) and set(value) == set(expected.split()), f"{where}: wrong fields")


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def boolean(value, where):
    require(type(value) is bool, f"{where}: expected boolean")


def members(value, domain, where, unique=True):
    require(isinstance(value, list), f"{where}: expected list")
    require(all(isinstance(x, str) and x in domain for x in value), f"{where}: unknown value")
    require(not unique or len(value) == len(set(value)), f"{where}: duplicate set member")


def known_events(spec_dir):
    return set(re.findall(r'(?:Plain|IsEvent|JobEv|ClEv|MsgEv|CJEv)\("(\w+)"',
                          (Path(spec_dir) / "Trace.tla").read_text()))


def validate_trace(path, spec_dir, report_path=None):
    path = Path(path)
    raw = path.read_bytes()
    require(raw.endswith(b"\n"), "trace is missing its final newline")
    lines = raw.splitlines()
    require(len(lines) >= 2 and all(lines), "empty trace or blank record")
    records = [json.loads(line) for line in lines]
    cfg = records[0]
    require(cfg.get("tag") == "config", "first record must be config")
    for field in ("jobs", "clients", "units"):
        v = cfg.get(field)
        require(isinstance(v, list) and all(isinstance(x, str) for x in v), f"config.{field}: expected names")
        require(len(v) == len(set(v)), f"config.{field}: duplicate name")
    jobs, clients, units = map(set, (cfg["jobs"], cfg["clients"], cfg["units"]))
    require(jobs and clients and "None" not in jobs | clients | units, "empty/invalid topology")
    for field in ("need", "max_jobs", "max_schedule_count", "expiry"):
        require(integer(cfg.get(field), 0 if field == "need" else 1), f"config.{field}: invalid integer")
    for field in ("deploy_sites", "min_sites", "required", "real_job_ids"):
        require(isinstance(cfg.get(field), dict) and set(cfg[field]) == jobs, f"config.{field}: incomplete job map")
    require(set(cfg.get("real_clients", {})) == clients, "config.real_clients: incomplete client map")
    for j in jobs:
        members(cfg["deploy_sites"][j], clients, "config.deploy_sites")
        members(cfg["required"][j], set(cfg["deploy_sites"][j]), "config.required")
        require(integer(cfg["min_sites"][j]), "config.min_sites: invalid integer")
    actions = known_events(spec_dir)
    require(len(actions) > 0, "no Trace wrappers found")
    counts = collections.Counter()
    statuses = {"SUBMITTED", "DISPATCHED", "RUNNING", "DELETED", "FINISHED:COMPLETED", "FINISHED:ABORTED",
                "FINISHED:FAILED_TO_RUN", "FINISHED:EXECUTION_EXCEPTION", "FINISHED:ABNORMAL",
                "FINISHED:CAN_NOT_SCHEDULE"}
    msg_actions = {"SpUpdateRunStatus", "SpProcessJobFailure", "SjHandleAbort", "CpCheckResource",
                   "CpCancelResource", "CpStartAllocate", "CpStartAllocateAppMissing", "CpAbortApp", "LoseMsg"}
    arg_actions = {"RunnerDeployJob", "SjFinish", "CjExit", "SpWaitRead"}
    previous_ts = 0
    for i, row in enumerate(records):
        ts = row.get("ts")
        require(isinstance(ts, str) and ts.isdigit(), f"line {i+1}: missing real timestamp")
        now = int(ts)
        require(1_577_836_800_000_000_000 < now < time.time_ns() + 60_000_000_000,
                f"line {i+1}: timestamp outside wall-clock range")
        require(now >= previous_ts, f"line {i+1}: timestamp moved backwards")
        previous_ts = now
        if i == 0:
            continue
        require(row.get("tag") == "trace", f"line {i+1}: record would be filtered by Trace.tla")
        require(type(row.get("seq")) is int and row["seq"] == i, f"line {i+1}: noncontiguous sequence")
        require(isinstance(row.get("thread"), str) and row["thread"], f"line {i+1}: missing emitting thread")
        e = row.get("event")
        require(isinstance(e, dict), f"line {i+1}: missing event")
        name = e.get("name")
        require(name in actions, f"event {i}: unknown action {name}")
        counts[name] += 1
        require(e.get("job") in jobs | {"None"} and e.get("cl") in clients | {"None"},
                f"event {i}: unknown job/client")
        if name in msg_actions:
            m = e.get("msg")
            require(isinstance(m, dict), f"event {i}: missing message")
            require({"type", "job", "cl", "att", "ok", "code", "flag"} <= set(m), f"event {i}: incomplete message")
            require(m["type"] in {"CHECK", "CHECK_REP", "START", "START_REP", "ABORT", "CANCEL",
                                  "REPORT", "RUNSTATUS", "SJABORT"}, f"event {i}: unknown message type")
            require(m["job"] in jobs and m["cl"] in clients | {"None"}, f"event {i}: invalid message mapping")
            require(integer(m["att"]) and integer(m["code"]), f"event {i}: invalid message integer")
            boolean(m["ok"], "message.ok")
            boolean(m["flag"], "message.flag")
        if name in arg_actions:
            a = e.get("arg")
            require(isinstance(a, dict), f"event {i}: missing action arguments")
            if name == "RunnerDeployJob":
                members(a.get("failed"), clients, "arg.failed")
            elif name == "SpWaitRead":
                boolean(a.get("record_present"), "arg.record_present")
            else:
                require(integer(a.get("rc")), "arg.rc: invalid integer")
                boolean(a.get("execution_error" if name == "SjFinish" else "descendants"), "arg.boolean")
        s = e.get("state")
        keys(s, "tagged scheduled_jobs running_jobs sessions jobs clients", f"event {i} state")
        for field in ("tagged", "scheduled_jobs", "running_jobs"):
            members(s[field], jobs, field)
        members(s["sessions"], clients, "sessions")
        require(set(s["jobs"]) == jobs and set(s["clients"]) == clients, f"event {i}: incomplete state domain")
        for j, t in s["jobs"].items():
            keys(t, "status schedule_count run_aborted pending latched run_process exception_process sj", j)
            require(t["status"] in statuses, f"{j}: unknown status")
            require(integer(t["schedule_count"]), f"{j}: invalid schedule_count")
            boolean(t["run_aborted"], j + ".run_aborted")
            keys(t["pending"], "present set", "pending")
            boolean(t["pending"]["present"], "pending.present")
            members(t["pending"]["set"], clients, "pending.set")
            require(t["latched"] in statuses | {"None"}, "unknown latch")
            require(t["sj"] in {"None", "Running", "Exited"}, "unknown SJ state")
            for field in ("run_process", "exception_process"):
                r = t[field]
                keys(r, "present finished exe_error rc parts", field)
                for b in ("present", "finished", "exe_error"):
                    boolean(r[b], field + "." + b)
                require(integer(r["rc"]), field + ": invalid rc")
                members(r["parts"], clients, field + ".parts")
        for c, t in s["clients"].items():
            if t.get("alive") is False:
                keys(t, "alive", c)
                continue
            keys(t, "alive free reserved jobs", c)
            boolean(t["alive"], c + ".alive")
            members(t["free"], units, c + ".free", unique=False)
            require(isinstance(t["reserved"], list), c + ": missing reservations")
            for r in t["reserved"]:
                keys(r, "att job units ttl", "reservation")
                require(integer(r["att"], 1) and r["job"] in jobs and integer(r["ttl"], 1),
                        "invalid reservation identity/TTL")
                members(r["units"], units, "reserved.units")
            require(set(t["jobs"]) == jobs, c + ": incomplete jobs")
            for j, cj in t["jobs"].items():
                keys(cj, "registration starting allocated cj", c + "." + j)
                r = cj["registration"]
                keys(r, "present st attached abort_req", "registration")
                for b in ("present", "attached", "abort_req"):
                    boolean(r[b], "registration." + b)
                require(r["st"] in {"None", "NOT_STARTED", "STARTING", "STARTED", "STOPPED", "EXCEPTION"},
                        "unknown registration status")
                keys(cj["starting"], "present units", "starting")
                boolean(cj["starting"]["present"], "starting.present")
                members(cj["starting"]["units"], units, "starting.units")
                members(cj["allocated"], units, "allocated")
                require(cj["cj"] in {"None", "Alive", "Exited"}, "unknown CJ state")
    digest = hashlib.sha256(raw).hexdigest()
    if report_path is not None:
        report = json.loads(Path(report_path).read_text())
        require(report["result"] == "ok" and report["exit_code"] == 0, "scenario did not succeed")
        require(report["trace_sha256"] == digest, "trace differs from the frozen scenario report")
        require(report["events"] == len(records) - 1 and report["event_counts"] == dict(counts),
                "trace event count differs from the scenario report")
        require(not report["harness_errors"] and not report["thread_deaths"], "unexpected harness/thread errors")
        require(report["network_quiesced"], "scenario ended with active network handlers")
        require(report["started_ns"] <= int(records[0]["ts"]) <= int(records[-1]["ts"]) <= report["finished_ns"],
                "trace timestamps are outside the recorded run")
        require(report["scenario"] == cfg["scenario"], "scenario/config identity mismatch")
    return {"trace": str(path.resolve()), "sha256": digest, "events": len(records)-1,
            "event_counts": dict(sorted(counts.items())), "result": "ok"}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("trace")
    ap.add_argument("--report")
    ap.add_argument("--spec-dir", default=str(Path(__file__).resolve().parents[2] / "spec"))
    a = ap.parse_args()
    try:
        result = validate_trace(a.trace, a.spec_dir, a.report)
    except (ValueError, KeyError, TypeError, OSError) as e:
        print(json.dumps({"result": "FAIL", "error": str(e)}))
        raise SystemExit(1)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
