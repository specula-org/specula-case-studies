#!/usr/bin/env python3
"""Project immutable Temporal observations. This module never imports/evaluates TLA+."""

import argparse
import copy
import datetime
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re

REV = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"
TERMS = {"Completed", "Failed", "Canceled", "STS", "STC", "SCT", "HB"}
TIMEOUT = {1: "STC", 2: "STS", 3: "SCT", 4: "HB"}
EVENTS = {
    10: "Scheduled",
    11: "Started",
    12: "Completed",
    13: "Failed",
    14: "Timeout",
    15: "CancelRequested",
    16: "Canceled",
}
EMPTY_AI = dict(
    present=False,
    attempt=0,
    started="No",
    request=0,
    version=0,
    startVersion=0,
    stamp=0,
    first=-1,
    scheduled=-1,
    startTime=-1,
    heartbeatTime=-1,
    details=0,
    cancel=False,
    mask=[],
)
EMPTY_TOKEN = dict(a=0, attempt=0, version=0, startVersion=0, worker="none", request=0)
EMPTY_REPLY = dict(
    id=0, kind="Internal", status="None", token=EMPTY_TOKEN, outcome=[], cancel=False, details=0, metadata=False
)
EMPTY_TX = dict(id=0, attempt=1, expected=0, range=0, reply=EMPTY_REPLY, cue=0, makeWFT=False, result="Pending")
EMPTY_CHECK = dict(stale=False, beforeAI=EMPTY_AI, afterAI=EMPTY_AI, beforeTerms=[], afterTerms=[])


def clone(value):
    return copy.deepcopy(value)


def unique(values):
    result = []
    for value in values:
        if value not in result:
            result.append(value)
    return result


def ns(value):
    if value is None:
        return None
    if isinstance(value, dict):
        return int(value.get("seconds", 0)) * 10**9 + int(value.get("nanos", 0))
    if value.startswith(("0001-", "1970-")):
        return None
    m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?Z", value)
    assert m, ("timestamp", value)
    return int(datetime.datetime.fromisoformat(m[1] + "+00:00").timestamp()) * 10**9 + int((m[2] or "").ljust(9, "0"))


def attr(event):
    if "Attributes" in event:
        return next(iter(event["Attributes"].values()))
    names = [k for k in event if k.endswith("_event_attributes") and event[k] is not None]
    assert len(names) == 1, (event.get("event_type"), names)
    return event[names[0]]


def status(error):
    if error is None:
        return "OK"
    typ = error["type"]
    if "NotFound" in typ or "AlreadyStarted" in typ:
        return "NotFound"
    if "ConditionFailed" in typ:
        return "Condition"
    if "OwnershipLost" in typ:
        return "Ownership"
    if "Timeout" in typ or "DeadlineExceeded" in typ or "Unavailable" in typ:
        return "Unknown"
    raise ValueError(("unclassified source error", error))


def event_kind(event):
    kind = event["event_type"]
    if isinstance(kind, int):
        return EVENTS.get(kind)
    return {
        "EVENT_TYPE_ACTIVITY_TASK_" + suffix: label
        for suffix, label in [
            ("SCHEDULED", "Scheduled"),
            ("STARTED", "Started"),
            ("COMPLETED", "Completed"),
            ("FAILED", "Failed"),
            ("TIMED_OUT", "Timeout"),
            ("CANCEL_REQUESTED", "CancelRequested"),
            ("CANCELED", "Canceled"),
        ]
    }.get(kind)


class Projector:
    def __init__(self, raw):
        self.raw = raw
        self.rows = [json.loads(line) for line in raw.read_text().splitlines()]
        self.config = clone(next(r["config"] for r in self.rows if r["tag"] == "config"))
        self.events = [r for r in self.rows if r.get("event")]
        self.bootstrap = next(i for i, r in enumerate(self.events) if r["event"] == "Bootstrap")
        self.origin = ns(self.events[self.bootstrap]["ts"]) // 10**6
        self.identities = self.events[self.bootstrap]["identity"]
        self.activity_ids = {}
        self.requests = {}
        self.task_ids = {}
        self.raw_tasks = {}
        self.task_logical = {}
        self.pending_history = []
        self.committed_history = []
        self.history_events = {}
        self.attempts = {}
        self.write_histories = {}
        self.retry_times = {}
        self.requeued = []
        self.wft_inputs = {}
        self.current_input = []
        self.consumed = []
        self.deliveries = {}
        self.dispatch_by_origin = {}
        self.transfers = {}
        self.call_tokens = {}
        self.pending_request = None
        self.pending_call = None
        self.output = []
        self.used = []
        self.current_raw = None
        self.previous_task_order = []
        self.initial_task_ids = set()
        self.initial_version = None
        # Identity order is the immutable ScheduledEventID order for this Run.
        all_ids = set()
        for r in self.events:
            c = r["observation"].get("cache", {}).get("mutableState", {})
            all_ids.update(int(k) for k in c.get("activity_infos", {}))
        self.activity_ids = {k: i + 1 for i, k in enumerate(sorted(all_ids))}
        policy = next(
            iter(
                next(
                    r["observation"]["cache"]["mutableState"]["activity_infos"]
                    for r in self.events
                    if r["observation"].get("cache", {}).get("mutableState", {}).get("activity_infos")
                ).values()
            )
        )
        for constant, field in [
            ("ScheduleToStart", "schedule_to_start_timeout"),
            ("StartToClose", "start_to_close_timeout"),
            ("ScheduleToClose", "schedule_to_close_timeout"),
            ("Heartbeat", "heartbeat_timeout"),
        ]:
            self.config[constant] = int(Decimal(policy[field][:-1]) * 1000)
        assert len(all_ids) == self.config["ActivityCount"]
        self.worker = self.config["Workers"][0]
        # Worker History receipts are independently observed payloads. Index by
        # accepted WFT StartedEventID, never by a predicted model transition.
        for r in self.events:
            o = r["observation"]
            if o.get("boundary") == "worker-history-receipt":
                response = o["response"]
                self.wft_inputs[int(response["started_event_id"])] = response["history"]["events"]
        for r in self.events[: self.bootstrap]:
            o = r["observation"]
            if o.get("sqlSnapshot"):
                self.initial_version = o["sqlSnapshot"]["dbRecordVersion"]
                self.initial_task_ids = {int(t["taskId"]) for t in o["sqlSnapshot"]["tasks"]}
        assert self.initial_version is not None
        self.config["InitialDBVersion"] = self.initial_version
        self.s = self.initial_state()

    def time(self, value):
        n = ns(value)
        return -1 if n is None else n // 10**6 - self.origin + 1

    def allocate_request(self, uuid):
        if not uuid:
            return 0
        if uuid not in self.requests:
            self.requests[uuid] = self.s["nextRequest"]
            self.s["nextRequest"] += 1
        return self.requests[uuid]

    def wf_empty(self):
        return dict(
            ai=[clone(EMPTY_AI) for _ in self.activity_ids],
            scheduled=[],
            history=[],
            buffer=[],
            wft="Started",
            seen=[],
            consumed=[],
            open=True,
        )

    def initial_state(self):
        lists = [
            "newTasks",
            "tasks",
            "claimed",
            "ackable",
            "copies",
            "matching",
            "dispatchReturns",
            "startCalls",
            "startMsgs",
            "polls",
            "lostStarts",
            "pollReplies",
            "tokens",
            "requests",
            "issuedRequests",
            "replies",
            "observed",
            "acknowledged",
            "cancelObserved",
            "writes",
            "receipts",
            "historyAppends",
            "committedOutcomes",
            "notifyPending",
            "notified",
            "appended",
        ]
        s = {k: [] for k in lists}
        s.update(
            now=1,
            cache=self.wf_empty(),
            db=self.wf_empty(),
            valid=True,
            watermark=[-1] * len(self.activity_ids),
            dbVersion=self.initial_version,
            range=1,
            owner=1,
            needFence=False,
            phase="Idle",
            tx=clone(EMPTY_TX),
            nextTxn=1,
            nextTask=1,
            nextDelivery=1,
            nextRequest=1,
            lastCheck=clone(EMPTY_CHECK),
            readback=dict(version=0, range=0, outcomes=[]),
            traceComplete=False,
            keyFloor=0,
        )
        return s

    def project_ai(self, ai):
        if ai is None:
            return clone(EMPTY_AI)
        for constant, field in [
            ("ScheduleToStart", "schedule_to_start_timeout"),
            ("StartToClose", "start_to_close_timeout"),
            ("ScheduleToClose", "schedule_to_close_timeout"),
            ("Heartbeat", "heartbeat_timeout"),
        ]:
            assert int(Decimal(ai[field][:-1]) * 1000) == self.config[constant], ("policy changed", constant, ai[field])
        assert (
            ai["has_retry_policy"] == self.config["HasRetryPolicy"]
            and ai["retry_maximum_attempts"] == self.config["MaximumAttempts"]
        )
        attempt = int(ai["attempt"])
        a = self.activity_ids[int(ai["scheduled_event_id"])]
        self.attempts[a] = attempt
        started = int(ai["started_event_id"])
        request = ai["request_id"]
        assert not request or request in self.requests, ("unobserved start request", request)
        return dict(
            present=True,
            attempt=attempt,
            started="No" if started == 0 else "Transient" if started == -124 else "Event",
            request=self.requests.get(request, 0),
            version=int(ai["version"]),
            startVersion=int(ai["start_version"]),
            stamp=int(ai["stamp"]),
            first=self.time(ai["first_scheduled_time"]),
            scheduled=self.time(ai["scheduled_time"]),
            startTime=self.time(ai["started_time"]),
            heartbeatTime=self.time(ai["last_heartbeat_update_time"]),
            details=int(bool(ai["last_heartbeat_details"] and ai["last_heartbeat_details"].get("payloads"))),
            cancel=ai["cancel_requested"],
            mask=[k for bit, k in [(1, "STC"), (2, "STS"), (4, "SCT"), (8, "HB")] if ai["timer_task_status"] & bit],
        )

    def project_events(self, events):
        result = []
        for e in events:
            kind = event_kind(e)
            if kind is None:
                continue
            at = attr(e)
            sid = int(e["event_id"]) if kind == "Scheduled" else int(at["scheduled_event_id"])
            a = self.activity_ids[sid]
            if kind == "Scheduled":
                attempt = 1
            elif kind == "Started":
                attempt = int(at.get("attempt", 1))
                self.attempts[a] = attempt
            else:
                attempt = self.attempts.get(a, 1)
            if kind == "Timeout":
                failure = at["failure"]
                fi = failure.get("timeout_failure_info") or failure.get("FailureInfo", {}).get("TimeoutFailureInfo")
                typ = fi["timeout_type"]
                kind = (
                    TIMEOUT[typ]
                    if isinstance(typ, int)
                    else {
                        "TIMEOUT_TYPE_" + x: y
                        for x, y in [
                            ("START_TO_CLOSE", "STC"),
                            ("SCHEDULE_TO_START", "STS"),
                            ("SCHEDULE_TO_CLOSE", "SCT"),
                            ("HEARTBEAT", "HB"),
                        ]
                    }[typ]
                )
            projected = dict(a=a, kind=kind, attempt=attempt)
            result.append(projected)
        return result

    def raw_builder_history(self, builder):
        return [e for batch in builder.get("batches") or [] for e in batch] + (builder.get("latestBatch") or [])

    def project_cache(self, capture, closed_events=None):
        if not capture.get("valid"):
            return self.wf_empty()
        m = capture["mutableState"]
        info = m["execution_info"]
        builder = capture["historyBuilder"]
        ai = [self.project_ai(m["activity_infos"].get(str(sid))) for sid in self.activity_ids]
        if closed_events is not None:
            self.pending_history = [e for batch in closed_events or [] for e in batch["Events"]]
        else:
            ev = self.raw_builder_history(builder)
            if ev:
                self.pending_history = ev
        historical = {int(e["event_id"]): e for e in self.committed_history if int(e["event_id"]) > 0}
        historical.update({int(e["event_id"]): e for e in self.pending_history if int(e["event_id"]) > 0})
        hist = self.project_events([historical[i] for i in sorted(historical)])
        buffer = self.project_events((builder.get("dbBuffer") or []) + (builder.get("memBuffer") or []))
        # At CloseTransaction the builder moved its buffer into the captured
        # serialized mutation; caller supplies it explicitly below.
        if closed_events is not None:
            buffer = self.project_events(m["buffered_events"])
        wft = (
            "Started"
            if int(info["workflow_task_started_event_id"])
            else "Pending"
            if int(info["workflow_task_scheduled_event_id"])
            else "None"
        )
        seen = (
            self.project_events(self.wft_inputs.get(int(info["workflow_task_started_event_id"]), []))
            if wft == "Started"
            else []
        )
        seen = [e for e in seen if e["kind"] in TERMS]
        return dict(
            ai=ai,
            scheduled=unique([e["a"] for e in hist if e["kind"] == "Scheduled"]),
            history=hist,
            buffer=buffer,
            wft=wft,
            seen=unique(seen),
            consumed=clone(self.consumed),
            open=capture["running"],
        )

    def project_db(self, snap):
        ai = [self.project_ai(snap["activityInfos"].get(str(sid))) for sid in self.activity_ids]
        info = snap["executionInfo"]
        wft = (
            "Started"
            if int(info["workflow_task_started_event_id"])
            else "Pending"
            if int(info["workflow_task_scheduled_event_id"])
            else "None"
        )
        h = self.project_events(self.committed_history)
        seen = (
            [
                e
                for e in self.project_events(self.wft_inputs.get(int(info["workflow_task_started_event_id"]), []))
                if e["kind"] in TERMS
            ]
            if wft == "Started"
            else []
        )
        return dict(
            ai=ai,
            scheduled=unique([e["a"] for e in h if e["kind"] == "Scheduled"]),
            history=h,
            buffer=self.project_events(snap["bufferedEvents"]),
            wft=wft,
            seen=unique(seen),
            consumed=clone(self.committed_consumed),
            open=snap["executionState"]["state"] == "WORKFLOW_EXECUTION_STATE_RUNNING",
        )

    def task_descriptor(self, t, category):
        if category.startswith("visibility"):
            return None
        if category.startswith("transfer"):
            sid = int(t["ScheduledEventID"])
            kind = "Transfer" if sid in self.activity_ids else "WFT"
            a = self.activity_ids.get(sid, 0)
            attempt = 1 if a else 0
        else:
            if "ScheduleAttempt" in t:
                return None  # WFT timeout interface, outside Activity timers.
            sid = int(t["EventID"])
            a = self.activity_ids.get(sid)
            if a is None:
                return None
            kind = TIMEOUT[int(t["TimeoutType"])] if "TimeoutType" in t else "Retry"
            attempt = int(t["Attempt"])
        return dict(
            id=int(t["TaskID"]),
            kind=kind,
            a=a,
            attempt=attempt,
            stamp=int(t.get("Stamp", 0)),
            version=int(t.get("Version", 0)),
            due=self.time(t["VisibilityTimestamp"]),
            logical=self.time(t["VisibilityTimestamp"]),
        )

    def descriptors(self, maps, allocate=False):
        raw = []
        for category, ts in maps.items():
            for t in ts:
                d = self.task_descriptor(t, category)
                if d is not None:
                    raw.append((d, t))

        # Source snapshots preserve per-category append order. Earlier snapshots
        # establish cross-category creation order (commands precede timer close).
        def identity(d):
            return (d["kind"], d["a"], d["attempt"], d["stamp"])

        order = {identity(d): i for i, d in enumerate(self.previous_task_order)}
        raw.sort(
            key=lambda pair: (
                order.get(identity(pair[0]), len(order)),
                {"Transfer": 0, "WFT": 1, "Retry": 2}.get(pair[0]["kind"], 3),
                pair[0]["a"],
            )
        )
        result = []
        for d, t in raw:
            real = d["id"]
            if allocate:
                assert real > 0
                if real not in self.task_ids:
                    self.task_ids[real] = self.s["nextTask"]
                    self.s["nextTask"] += 1
                previous = next(x for x in self.previous_task_order if identity(x) == identity(d))
                d["logical"] = previous["logical"]
                self.task_logical[real] = d["logical"]
                self.raw_tasks[real] = clone(t)
                d["id"] = self.task_ids[real]
            else:
                d["id"] = self.task_ids.get(real, 0)
            result.append(d)
        self.previous_task_order = clone(result)
        return result

    def db_tasks(self, snap):
        result = []
        for row in snap["tasks"]:
            real = int(row["taskId"])
            if real not in self.task_ids:
                continue
            t = row["task"]
            raw = self.raw_tasks[real]
            category = "transfer" if row["category"] == "transfer" else "timer"
            d = self.task_descriptor(raw, category)
            d["id"] = self.task_ids[real]
            d["due"] = self.time(t["visibility_time"])
            d["logical"] = self.task_logical[real]
            # Compare independently decoded persisted identity, not payload only.
            sid = int(t.get("scheduled_event_id", t.get("event_id", 0)))
            assert d["a"] == self.activity_ids.get(sid, 0)
            d["stamp"] = int(t["stamp"])
            d["version"] = int(t["version"])
            observed_kind = {
                "TASK_TYPE_TRANSFER_ACTIVITY_TASK": "Transfer",
                "TASK_TYPE_TRANSFER_WORKFLOW_TASK": "WFT",
                "TASK_TYPE_ACTIVITY_RETRY_TIMER": "Retry",
            }.get(t["task_type"])
            if t["task_type"] == "TASK_TYPE_ACTIVITY_TIMEOUT":
                observed_kind = {
                    "TIMEOUT_TYPE_START_TO_CLOSE": "STC",
                    "TIMEOUT_TYPE_SCHEDULE_TO_START": "STS",
                    "TIMEOUT_TYPE_SCHEDULE_TO_CLOSE": "SCT",
                    "TIMEOUT_TYPE_HEARTBEAT": "HB",
                }[t["timeout_type"]]
            assert observed_kind is not None, ("unmapped durable task type", t["task_type"])
            d["kind"] = observed_kind
            if row["category"] == "timer":
                d["attempt"] = int(t["schedule_attempt"])
            result.append(d)
        return result

    def audit_invocation(self, o):
        """Verify the immutable submitted payload independently of the cache view."""
        mutation = o["mutation"]
        s = self.s
        assert int(mutation["DBRecordVersion"]) == s["tx"]["expected"] + 1
        assert int(o["request"]["UpdateWorkflowMutation"]["DBRecordVersion"]) == int(mutation["DBRecordVersion"])
        info = mutation["ExecutionInfo"]
        state = mutation["ExecutionState"]
        wft = (
            "Started"
            if int(info.get("workflow_task_started_event_id", 0))
            else "Pending"
            if int(info.get("workflow_task_scheduled_event_id", 0))
            else "None"
        )
        assert wft == s["cache"]["wft"] and (int(state["state"]) == 2) == s["cache"]["open"]
        for sid, raw in mutation["UpsertActivityInfos"].items():
            ai = clone(raw)
            for key in ["version", "started_event_id", "stamp", "start_version", "timer_task_status"]:
                ai.setdefault(key, 0)
            ai.setdefault("request_id", "")
            ai.setdefault("cancel_requested", False)
            for key in ["started_time", "last_heartbeat_update_time", "last_heartbeat_details"]:
                ai.setdefault(key, None)
            for key in [
                "schedule_to_start_timeout",
                "start_to_close_timeout",
                "schedule_to_close_timeout",
                "heartbeat_timeout",
            ]:
                duration = ai[key]
                ai[key] = (
                    str(Decimal(duration.get("seconds", 0)) + Decimal(duration.get("nanos", 0)) / Decimal(10**9)) + "s"
                )
            assert self.project_ai(ai) == s["cache"]["ai"][self.activity_ids[int(sid)] - 1], (
                "submitted AI differs",
                sid,
            )
        for sid in mutation["DeleteActivityInfos"]:
            assert not s["cache"]["ai"][self.activity_ids[int(sid)] - 1]["present"]
        old_buffer = [] if mutation["ClearBufferedEvents"] else clone(s["db"]["buffer"])
        expected_buffer = old_buffer + self.project_events(mutation["NewBufferedEvents"] or [])
        # A same-payload internal retry can follow its own earlier commit.
        if s["tx"]["attempt"] == 1:
            assert expected_buffer == s["cache"]["buffer"], "submitted buffer differs"
        submitted_events = [e for batch in o["events"] or [] for e in batch["Events"]]
        assert self.project_events(submitted_events) == self.project_events(self.pending_history)
        submitted_tasks = []
        for category, tasks in mutation["Tasks"].items():
            for task in tasks:
                desc = self.task_descriptor(task, category)
                if desc is None:
                    continue
                raw_id = desc["id"]
                desc["id"] = self.task_ids[raw_id]
                desc["logical"] = self.task_logical[raw_id]
                submitted_tasks.append(desc)
        assert sorted(submitted_tasks, key=lambda t: t["id"]) == sorted(s["newTasks"], key=lambda t: t["id"])

    def token(self, t):
        sid = int(t["scheduled_event_id"])
        a = self.activity_ids[sid]
        attempt = int(t["attempt"])
        matching = [
            c
            for c in self.s["startCalls"]
            if c["a"] == a and self.call_tokens.get(c["id"], {}).get("attempt") == attempt
        ]
        assert matching, ("token without observed start", a, attempt)
        call = matching[-1]
        return dict(
            a=a,
            attempt=attempt,
            version=int(t["version"]),
            startVersion=int(t["start_version"]),
            worker=call["worker"],
            request=call["id"],
        )

    def terms(self, wf):
        return unique([e for e in wf["history"] + wf["buffer"] if e["kind"] in TERMS])

    def emit(self, name, args=None):
        row = dict(
            tag="trace",
            schemaVersion=1,
            seq=len(self.output) + 1,
            event=name,
            args=args or {},
            state=clone(self.s),
            evidence=dict(
                sourceRevision=REV,
                basis="implementation",
                complete=True,
                ordering="lease-and-transaction",
                artifact=str(self.raw),
            ),
            rawSeq=self.current_raw["seq"],
        )
        if name == "Bootstrap":
            row["config"] = {
                k: clone(self.config[k])
                for k in [
                    "ActivityCount",
                    "Workers",
                    "NamespaceVersion",
                    "IncrementRetryStamp",
                    "HasRetryPolicy",
                    "MaximumAttempts",
                    "InitialInterval",
                    "BackoffCoefficient",
                    "MaximumInterval",
                    "ScheduleToStart",
                    "StartToClose",
                    "ScheduleToClose",
                    "Heartbeat",
                    "WorkflowExpiration",
                    "KeepInitialWFT",
                    "InitialDBVersion",
                    "sourceRevision",
                    "backend",
                    "journalMode",
                    "synchronous",
                    "eagerRequest",
                    "workerControlCancellation",
                    "administrativeExtensions",
                ]
            }
        self.output.append(row)

    def advance(self, value):
        tm = self.time(value)
        assert tm >= self.s["now"], ("clock ordering", self.current_raw["seq"], tm, self.s["now"])
        if tm > self.s["now"]:
            self.s["now"] = tm
            self.emit("AdvanceTime", {"time": tm})

    def mutation(self, o, reply=None, cue=0):
        self.s["phase"] = "Mutated"
        self.s["tx"] = clone(EMPTY_TX)
        self.s["tx"].update(
            id=self.s["nextTxn"],
            expected=o["cache"]["dbRecordVersion"],
            range=self.s["owner"],
            cue=cue,
            reply=clone(reply or EMPTY_REPLY),
        )
        self.s["nextTxn"] += 1
        self.previous_task_order = []
        self.s["cache"] = self.project_cache(o["cache"])
        self.s["newTasks"] = self.descriptors(o["cache"]["tasks"])
        self.s["watermark"] = [self.time(o["cache"]["watermark"].get(str(k))) for k in self.activity_ids]

    def process(self):
        self.committed_consumed = []
        for r in self.events[self.bootstrap :]:
            self.current_raw = r
            o = r["observation"]
            name = r["event"]
            args = {}
            s = self.s
            boundary = o.get("boundary")
            if name == "RetryPolicyTimes":
                self.retry_times[int(o["scheduledEventId"])] = o
                self.used.append({"rawSeq": r["seq"], "role": "source retry clocks"})
                continue
            if boundary == "delayed-delegate-return":
                self.used.append({"rawSeq": r["seq"], "role": boundary})
                continue
            if name == "Bootstrap":
                m = o["response"]["database_mutable_state"]
                assert not m["activity_infos"] and not m["buffered_events"]
                assert int(m["execution_info"]["workflow_task_started_event_id"]) > 0
                self.emit(name)
                continue
            if boundary in {
                "worker-history-receipt",
                "worker-completion-receipt",
                "admin-force-reload-receipt",
                "sqlite-consistent-backup",
            }:
                self.used.append({"rawSeq": r["seq"], "role": boundary})
                continue
            if name == "AddActivityTaskScheduledEvent":
                times = [ai["scheduled_time"] for ai in o["cache"]["mutableState"]["activity_infos"].values()]
                assert len({self.time(t) for t in times}) == 1, (
                    "schedule batch crosses clock ticks: needs per-Activity schedule times"
                )
                self.advance(times[0])
                self.mutation(o)
            elif name == "CloseTransactionAsMutation":
                s["cache"] = self.project_cache(o["cache"], o["events"])
                s["newTasks"] = self.descriptors(o["mutation"]["Tasks"])
                s["phase"] = "Closed"
                s["watermark"] = [self.time(o["cache"]["watermark"].get(str(k))) for k in self.activity_ids]
            elif name == "SetAndTrackTaskKeys":
                self.advance(o["allocationTime"])
                s["keyFloor"] = self.time(o["minScheduledTime"])
                args = {"minimum": s["keyFloor"]}
                s["newTasks"] = self.descriptors(o["request"]["UpdateWorkflowMutation"]["Tasks"], True)
                s["tx"]["range"] = int(o["request"]["RangeID"])
                s["phase"] = "Prepared"
            elif name == "SubmitWorkflowMutation":
                self.audit_invocation(o)
                w = dict(
                    id=s["tx"]["id"],
                    attempt=s["tx"]["attempt"],
                    expected=s["tx"]["expected"],
                    range=int(o["request"]["RangeID"]),
                    wf=clone(s["cache"]),
                    tasks=clone(s["newTasks"]),
                )
                self.write_histories[(w["id"], w["attempt"])] = clone(self.pending_history)
                s["writes"].append(w)
                s["phase"] = "Waiting"
            elif name == "AppendHistoryNodes":
                assert s["writes"], "no observed invocation submission"
                w = next(
                    w
                    for w in s["writes"]
                    if w["expected"] + 1 == int(o["request"]["UpdateWorkflowMutation"]["DBRecordVersion"])
                    and w["range"] == int(o["request"]["RangeID"])
                )
                args = {"write": clone(w)}
                s["appended"] = unique(s["appended"] + [dict(id=w["id"], attempt=w["attempt"])])
                s["historyAppends"] = unique(
                    s["historyAppends"]
                    + [dict(id=w["id"], events=self.project_events(self.write_histories[(w["id"], w["attempt"])]))]
                )
            elif name == "ApplyWorkflowMutationTx":
                assert o["commitConfirmed"] is True
                version = o["sqlSnapshot"]["dbRecordVersion"]
                w = next(w for w in s["writes"] if w["expected"] + 1 == version)
                args = {"write": clone(w)}
                h = {int(e["event_id"]): e for e in self.committed_history}
                h.update({int(e["event_id"]): e for e in self.write_histories[(w["id"], w["attempt"])]})
                self.committed_history = [h[k] for k in sorted(h)]
                self.committed_consumed = clone(self.consumed)
                s["db"] = self.project_db(o["sqlSnapshot"])
                s["dbVersion"] = version
                s["tasks"] = self.db_tasks(o["sqlSnapshot"])
                s["committedOutcomes"] = unique(s["committedOutcomes"] + self.terms(s["db"]))
                s["writes"].remove(w)
                s["receipts"].append(dict(id=w["id"], attempt=w["attempt"], status="Commit"))
            elif name == "ReturnPersistenceResult":
                s["phase"] = "Result"
                s["tx"]["result"] = status(o["error"])
                if s["tx"]["result"] in {"OK", "Unknown"}:
                    s["notifyPending"].append(s["tx"]["id"])
            elif name == "NotifyOnExecutionMutation":
                ident = s["tx"]["id"]
                args = {"id": ident}
                s["notifyPending"].remove(ident)
                s["notified"].append(ident)
            elif name == "FinishUpdateWorkflowExecution":
                ok = o["error"] is None
                s["cache"] = self.project_cache(o["cache"])
                s["valid"] = o["cache"]["valid"]
                s["watermark"] = [self.time(o["cache"].get("watermark", {}).get(str(k))) for k in self.activity_ids]
                if not ok:
                    s["tx"]["reply"]["status"] = status(o["error"])
                    if s["tx"]["cue"] in s["claimed"]:
                        s["claimed"].remove(s["tx"]["cue"])
                    if s["range"] == s["tx"]["range"] and status(o["error"]) in {"Unknown", "Ownership"}:
                        s["needFence"] = True
                if s["tx"]["reply"]["kind"] != "Internal":
                    s["replies"].append(clone(s["tx"]["reply"]))
                if ok and s["tx"]["cue"]:
                    s["ackable"] = unique(s["ackable"] + [s["tx"]["cue"]])
                s["phase"] = "Idle"
                s["tx"] = clone(EMPTY_TX)
                s["newTasks"] = []
                self.pending_history = []
                self.previous_task_order = []
            elif name == "ProcessActivityTask" or name == "ExecuteActivityRetryTimerTask":
                self.advance(r["ts"])
                real = int(o["task"]["TaskID"])
                task = next(t for t in s["tasks"] if t["id"] == self.task_ids[real])
                args = {"task": clone(task)}
                d = dict(
                    id=s["nextDelivery"], origin=task["id"], a=task["a"], stamp=task["stamp"], sent=s["now"], expires=-1
                )
                s["nextDelivery"] += 1
                s["copies"].append(d)
                s["claimed"].append(task["id"])
                self.dispatch_by_origin[real] = d
            elif name == "AddActivityTask":
                assert o["error"] is None
                assert not o["syncMatch"] or boundary == "sync-receiver-acceptance", (
                    "sync-match acceptance hook missing"
                )
                real = int(o["request"]["clock"]["clock"])
                d = self.dispatch_by_origin[real]
                created = self.time(o["taskInfo"]["create_time"])
                if created > s["now"]:
                    self.advance(o["taskInfo"]["create_time"])
                args = {"delivery": clone(d), "created": created}
                s["copies"].remove(d)
                d = clone(d)
                d["expires"] = self.time(o["taskInfo"]["expiry_time"])
                s["matching"].append(d)
                self.dispatch_by_origin[real] = d
                s["dispatchReturns"].append(d["origin"])
            elif name == "DeliverAddActivityTaskResponse":
                ident = self.task_ids[int(o["task"]["TaskID"])]
                args = {"id": ident}
                s["dispatchReturns"].remove(ident)
                s["ackable"] = unique(s["ackable"] + [ident])
            elif name == "PollActivityTaskQueue":
                req = o["request"]
                real = int(req["clock"]["clock"])
                d = next(
                    (
                        x
                        for x in s["matching"]
                        if x["origin"] == 0 and x["a"] == self.activity_ids[int(req["scheduled_event_id"])]
                    ),
                    self.dispatch_by_origin[real],
                )
                args = {"delivery": clone(d), "worker": req["poll_request"]["identity"]}
                call = dict(
                    id=self.allocate_request(req["request_id"]),
                    a=self.activity_ids[int(req["scheduled_event_id"])],
                    stamp=int(req["stamp"]),
                    worker=req["poll_request"]["identity"],
                    sent=d["sent"],
                    expires=d["expires"],
                )
                s["matching"].remove(d)
                for key in ["startCalls", "startMsgs", "polls"]:
                    s[key].append(clone(call))
            elif name in {"RecordActivityTaskStarted", "RecordActivityTaskStartedDuplicate"}:
                req = o["request"]
                call = next(c for c in s["startMsgs"] if c["id"] == self.requests[req["request_id"]])
                args = {"call": clone(call)}
                ai = o["cache"]["mutableState"]["activity_infos"][req["scheduled_event_id"]]
                if name == "RecordActivityTaskStarted":
                    self.advance(ai["started_time"])
                response = o["response"]
                token = dict(
                    a=call["a"],
                    attempt=int(response["attempt"]),
                    version=int(response["version"]),
                    startVersion=int(response["start_version"]),
                    worker=call["worker"],
                    request=call["id"],
                )
                self.call_tokens[call["id"]] = token
                reply = clone(EMPTY_REPLY)
                reply.update(
                    id=call["id"],
                    kind="Start",
                    status="OK",
                    token=token,
                    metadata=name == "RecordActivityTaskStarted",
                    details=int(bool(response["heartbeat_details"] and response["heartbeat_details"].get("payloads"))),
                )
                s["startMsgs"].remove(call)
                self.mutation(o, reply)
            elif name == "RetryRecordActivityTaskStarted":
                callid = self.requests[o["request"]["request_id"]]
                call = next(c for c in s["startCalls"] if c["id"] == callid)
                args = {"call": clone(call)}
                s["startMsgs"].append(clone(call))
            elif name == "RecordActivityTaskStartedRejected":
                callid = self.requests[o["request"]["request_id"]]
                call = next(c for c in s["startMsgs"] if c["id"] == callid)
                args = {"call": clone(call)}
                s["startMsgs"].remove(call)
                reply = clone(EMPTY_REPLY)
                reply.update(id=callid, kind="Start", status="NotFound")
                s["replies"].append(reply)
            elif name == "ReceiveRecordActivityTaskStartedResponse":
                callid = self.requests[o["request"]["request_id"]]
                reply = next(q for q in s["replies"] if q["id"] == callid)
                args = {"response": clone(reply)}
                s["replies"].remove(reply)
                s["polls"] = [q for q in s["polls"] if q["id"] != callid]
                s["lostStarts"] = [i for i in s["lostStarts"] if i != callid]
                if reply["status"] == "OK":
                    s["pollReplies"].append(reply)
            elif name == "DeliverPollActivityTaskQueueResponse":
                token = self.token(o["token"])
                reply = next(q for q in s["pollReplies"] if q["token"] == token)
                args = {"response": clone(reply)}
                s["pollReplies"].remove(reply)
                s["observed"].append(reply)
                s["tokens"] = unique(s["tokens"] + [token])
            elif name == "SendActivityRequest":
                token = self.token(o["token"])
                req = dict(id=s["nextRequest"], token=token, kind=o["kind"], details=o["details"])
                s["nextRequest"] += 1
                s["requests"].append(req)
                s["issuedRequests"].append(clone(req))
                self.pending_request = req
                args = {"token": token, "kind": req["kind"], "details": req["details"]}
            elif name in {
                "RecordActivityTaskHeartbeat",
                "RespondActivityTaskCompleted",
                "RespondActivityTaskFailed",
                "RespondActivityTaskCanceled",
                "RejectActivityRequest",
            }:
                req = self.pending_request
                assert req and req in s["requests"]
                args = {"request": clone(req)}
                before = self.project_cache(o["before"])
                a = req["token"]["a"]
                if name in {"RecordActivityTaskHeartbeat", "RespondActivityTaskFailed"}:
                    ai = o["cache"]["mutableState"]["activity_infos"].get(
                        str(next(k for k, v in self.activity_ids.items() if v == a))
                    )
                    if ai:
                        self.advance(ai["last_heartbeat_update_time"])
                after = self.project_cache(o["cache"])
                s["requests"].remove(req)
                reply = clone(EMPTY_REPLY)
                reply.update(
                    id=req["id"],
                    kind=req["kind"],
                    status="NotFound" if o["error"] else "OK",
                    token=req["token"],
                    outcome=[e for e in self.terms(after) if e not in self.terms(before)],
                    cancel=before["ai"][a - 1]["cancel"] if name == "RecordActivityTaskHeartbeat" else False,
                )
                if name == "RejectActivityRequest":
                    s["replies"].append(reply)
                else:
                    self.mutation(o, reply)
                    s["tx"]["makeWFT"] = o["postActions"]["CreateWorkflowTask"]
                s["lastCheck"] = dict(
                    stale=not before["ai"][a - 1]["present"]
                    or before["ai"][a - 1]["attempt"] != req["token"]["attempt"],
                    beforeAI=before["ai"][a - 1],
                    afterAI=after["ai"][a - 1],
                    beforeTerms=self.terms(before),
                    afterTerms=self.terms(after),
                )
            elif name == "DeliverActivityResponse":
                req = self.pending_request
                reply = next(q for q in s["replies"] if q["id"] == req["id"])
                args = {"response": clone(reply)}
                assert (o["error"] is None) == (reply["status"] == "OK")
                s["replies"].remove(reply)
                s["observed"].append(reply)
                if reply["status"] == "OK":
                    s["acknowledged"] = unique(s["acknowledged"] + reply["outcome"])
                if reply["kind"] == "Heartbeat" and o["response"]["cancel_requested"]:
                    s["cancelObserved"] = unique(s["cancelObserved"] + [reply["token"]])
                self.pending_request = None
            elif name in {"PersistenceTimeoutBeforeWrite", "PersistenceResponseTimeout"}:
                if name == "PersistenceTimeoutBeforeWrite":
                    assert o["delegateExecuted"] is False
                    w = next(w for w in s["writes"] if w["id"] == s["tx"]["id"] and w["attempt"] == s["tx"]["attempt"])
                    s["writes"].remove(w)
                    s["receipts"].append(dict(id=w["id"], attempt=w["attempt"], status="Aborted"))
                s["tx"]["result"] = "Unknown"
            elif name == "RetryPersistenceAfterUnavailable":
                assert any(x["id"] == s["tx"]["id"] and x["status"] == "Commit" for x in s["receipts"])
                s["tx"]["attempt"] += 1
                s["phase"] = "Prepared"
            elif name == "RejectWorkflowMutationTx":
                req = o["request"]
                w = next(
                    w
                    for w in s["writes"]
                    if w["expected"] + 1 == int(req["UpdateWorkflowMutation"]["DBRecordVersion"])
                    and w["range"] == int(req["RangeID"])
                )
                args = {"write": clone(w)}
                s["writes"].remove(w)
                s["receipts"].append(dict(id=w["id"], attempt=w["attempt"], status=status(o["error"])))
            elif name == "LoseShardContext":
                s["needFence"] = True
            elif name == "ReacquireShard":
                s["range"] = int(o["rangeId"])
            elif name == "ShardReady":
                s["owner"] = int(o["rangeId"])
                s["needFence"] = False
            elif name == "LoseAPIResponse":
                ident = self.requests[o["request"]["request_id"]]
                reply = next(q for q in s["replies"] if q["id"] == ident)
                args = {"response": clone(reply)}
                s["replies"].remove(reply)
                s["lostStarts"].append(ident)
            elif name == "RetryMatchingActivityTask":
                a = self.activity_ids.get(int(o["task"]["data"]["scheduled_event_id"]))
                calls = [c for c in s["polls"] if c["a"] == a and c["id"] in s["lostStarts"]]
                if not calls:
                    self.used.append(
                        {"rawSeq": r["seq"], "role": "WFT or Matching reprocess without a lost History start call"}
                    )
                    continue
                call = calls[0]
                args = {"call": clone(call)}
                s["polls"].remove(call)
                s["lostStarts"].remove(call["id"])
                s["matching"].append(
                    dict(
                        id=s["nextDelivery"],
                        origin=0,
                        a=a,
                        stamp=call["stamp"],
                        sent=call["sent"],
                        expires=call["expires"],
                    )
                )
                s["nextDelivery"] += 1
            elif name == "RetryActivityRequest":
                req = self.pending_request
                assert self.token(o["token"]) == req["token"]
                args = {"request": clone(req)}
                reply = next(q for q in s["replies"] if q["id"] == req["id"])
                assert reply["status"] == "Condition"
                s["replies"].remove(reply)
                s["requests"].append(clone(req))
            elif name == "DropExpiredMatchingTask":
                sid = int(o["task"]["data"]["scheduled_event_id"])
                if sid not in self.activity_ids:
                    self.used.append({"rawSeq": r["seq"], "role": "excluded WFT queue expiry"})
                    continue
                self.advance(r["ts"])
                expiry = self.time(o["task"]["data"]["expiry_time"])
                a = self.activity_ids[sid]
                d = next(d for d in s["matching"] if d["a"] == a and d["expires"] == expiry)
                args = {"delivery": clone(d)}
                s["matching"].remove(d)
            elif name == "DrainMatchingObservation":
                self.used.append({"rawSeq": r["seq"], "role": "completed harness poll of obsolete Matching work"})
                continue
            elif name == "HandleCommandRequestCancelActivity":
                commands = o["request"]["commands"]
                sid = int(
                    next(
                        c["request_cancel_activity_task_command_attributes"]["scheduled_event_id"]
                        for c in commands
                        if c["command_type"] == "COMMAND_TYPE_REQUEST_CANCEL_ACTIVITY_TASK"
                    )
                )
                args = {"activity": self.activity_ids[sid]}
                self.consumed = unique(self.consumed + clone(s["cache"]["seen"]))
                self.mutation(o)
                s["tx"]["makeWFT"] = not s["cache"]["ai"][self.activity_ids[sid] - 1]["present"]
            elif name == "ExecuteActivityTimeoutTask":
                self.advance(o["referenceTime"])
                real = int(o["task"]["TaskID"])
                task = next(t for t in s["tasks"] if t["id"] == self.task_ids[real])
                args = {"task": clone(task)}
                if task["id"] in s["ackable"]:
                    s["ackable"].remove(task["id"])
                    s["claimed"] = [x for x in s["claimed"] if x != task["id"]]
                    self.emit("RedeliverTask", {"task": clone(task)})
                if o["mutated"]:
                    s["claimed"] = unique(s["claimed"] + [task["id"]])
                    self.mutation(o, cue=task["id"])
                    s["tx"]["makeWFT"] = o["makeWFT"]
                else:
                    s["ackable"] = unique(s["ackable"] + [task["id"]])
            elif name == "ClearWorkflowCache":
                s["valid"] = False
                s["cache"] = self.wf_empty()
                s["watermark"] = [-1] * len(self.activity_ids)
                self.pending_history = []
            elif name == "ReadWorkflowExecution":
                snap = o["sqlSnapshot"]
                assert int(o["returnedVersion"]) == snap["dbRecordVersion"], "unbracketed independent read"
                assert snap["dbRecordVersion"] == s["dbVersion"] and snap["rangeId"] == s["range"]
                assert self.project_db(snap) == s["db"], "independent read differs from committed observation"
                assert sorted(self.db_tasks(snap), key=lambda t: t["id"]) == sorted(
                    s["tasks"], key=lambda t: t["id"]
                ), "task retirement observation missing"
                s["readback"] = dict(
                    version=snap["dbRecordVersion"], range=snap["rangeId"], outcomes=self.terms(s["db"])
                )
            elif name == "LoadMutableState":
                assert int(o["cache"]["dbRecordVersion"]) == s["dbVersion"], (
                    "loaded cache version differs from independent read"
                )
                if s["phase"] == "RejectedClose":
                    name = "ReloadAfterRejectedWorkflowClose"
                    s["phase"] = "CloseReloaded"
                s["cache"] = self.project_cache(o["cache"])
                s["valid"] = True
                s["watermark"] = [
                    0
                    if self.time(o["cache"]["watermark"].get(str(k))) < -1 and str(k) in o["cache"]["watermark"]
                    else self.time(o["cache"]["watermark"].get(str(k)))
                    for k in self.activity_ids
                ]
                s["readback"] = dict(version=s["dbVersion"], range=s["range"], outcomes=self.terms(s["db"]))
            elif name == "HandleCommandCompleteWorkflowRejected":
                s["tx"] = clone(EMPTY_TX)
                s["tx"].update(id=s["nextTxn"], expected=o["before"]["dbRecordVersion"], range=s["owner"])
                s["nextTxn"] += 1
                s["phase"] = "RejectedClose"
                s["valid"] = False
                s["cache"] = self.wf_empty()
                s["watermark"] = [-1] * len(self.activity_ids)
                s["newTasks"] = []
                self.pending_history = []
                self.previous_task_order = []
            elif name == "FailWorkflowTaskAfterRejectedClose":
                assert s["phase"] == "CloseReloaded"
                s["cache"] = self.project_cache(o["cache"])
                s["newTasks"] = self.descriptors(o["cache"]["tasks"])
                s["phase"] = "Mutated"
                s["tx"]["makeWFT"] = True
            elif name == "WorkflowCloseRejectedObservation":
                assert o["error"]["type"] == "*serviceerror.InvalidArgument"
                self.used.append({"rawSeq": r["seq"], "role": "rejected close RPC after durable WFT failure"})
                continue
            elif name == "RedeliverTask":
                task = next(t for t in s["tasks"] if t["id"] == self.task_ids[int(o["task"]["TaskID"])])
                args = {"task": clone(task)}
                s["ackable"].remove(task["id"])
                s["claimed"] = [i for i in s["claimed"] if i != task["id"]]
            elif name == "RecordWorkflowTaskStarted":
                self.mutation(o)
            elif name == "RespondWorkflowTaskCompleted":
                self.consumed = unique(self.consumed + clone(s["cache"]["seen"]))
                self.mutation(o)
            elif name == "RangeCompleteHistoryTasks":
                assert o["error"] is None
                req = o["request"]
                cat = o["categoryId"]
                retired = []
                for t in s["tasks"]:
                    rawid = next(k for k, v in self.task_ids.items() if v == t["id"])
                    if (
                        cat == 1
                        and t["kind"] in {"Transfer", "WFT"}
                        and rawid < int(req["ExclusiveMaxTaskKey"]["TaskID"])
                    ):
                        retired.append(t)
                    if (
                        cat == 2
                        and t["kind"] not in {"Transfer", "WFT"}
                        and t["due"] < self.time(req["ExclusiveMaxTaskKey"]["FireTime"])
                    ):
                        retired.append(t)
                if not retired:
                    self.used.append({"rawSeq": r["seq"], "role": "retirement of excluded/no selected rows"})
                    continue
                args = {"tasks": clone(retired)}
                s["tasks"] = [t for t in s["tasks"] if t not in retired]
                ids = {t["id"] for t in retired}
                s["ackable"] = [i for i in s["ackable"] if i not in ids]
                s["claimed"] = [i for i in s["claimed"] if i not in ids]
            elif name == "FinishTrace":
                assert o["implementationEndpointComplete"] and o["terminalEventsConsumed"]
                assert not o["finalReadback"]["database_mutable_state"]["activity_infos"]
                assert self.project_events(o["history"]["history"]["events"]) == s["db"]["history"], (
                    "independently retrieved logical History differs"
                )
                consumed = self.project_events(o["terminalEventsConsumed"])
                assert all(e in s["db"]["consumed"] for e in consumed) and len(consumed) == self.config["ActivityCount"]
                s["traceComplete"] = True
            else:
                raise NotImplementedError((r["seq"], name))
            self.emit(name, args)
        assert self.output[-1]["event"] == "FinishTrace"
        return self.output


def main():
    p = argparse.ArgumentParser()
    p.add_argument("raw", type=Path)
    p.add_argument("output", type=Path)
    args = p.parse_args()
    projector = Projector(args.raw)
    rows = projector.process()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows))
    args.output.with_suffix(".provenance.json").write_text(
        json.dumps(
            {
                "raw": str(args.raw),
                "sha256": hashlib.sha256(args.raw.read_bytes()).hexdigest(),
                "activityIds": projector.activity_ids,
                "requests": projector.requests,
                "tasks": projector.task_ids,
                "observationRoles": projector.used,
                "events": len(rows),
                "projectorSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            },
            indent=2,
        )
        + "\n"
    )
    print(f"{len(rows)} independently projected events: {args.output}")


if __name__ == "__main__":
    main()
