# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
"""Source-observation recorder. No TLA evaluator, protocol driver or verdict computation.

Only continuation/observer ledgers live here. Status, timestamps, bytes, callback
arguments, operation counts, outcomes and source identities come from real objects.
The writer lock is held for a single observation, never around user callbacks.
"""

import contextlib
import copy
import inspect
import json
import pathlib
import threading
import time

SHA = "53ba7ee567468ea7971dad4faccef13c6cb35dc2"
INLINE = ("inline", "-", "-")
WORKER = ("worker", "-", "-")
BUDGET = ("budget", "-", "-")
NULL_PAIR = ("-", "-")
ACTIVE = None
TLS = threading.local()
REAL_NS = time.time_ns
TERMINAL = {"completed", "failed", "aborted"}


class TraceError(BaseException):
    pass


class Fn(dict):
    """Typed TLA function; ordinary dictionaries remain records."""


class EventSet(list):
    """Small immutable-event sets; JSON records are deliberately unhashable."""


def encode(x):
    if isinstance(x, Fn):
        return {"__tla": "function", "entries": [{"key": encode(k), "value": encode(v)} for k, v in x.items()]}
    if isinstance(x, (set, EventSet)):
        return {"__tla": "set", "items": [encode(v) for v in (sorted(x) if isinstance(x, set) else x)]}
    if isinstance(x, dict):
        return {k: encode(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [encode(v) for v in x]
    assert x is not None, "null is not a model value"
    return x


def empty_event():
    return dict(pair=NULL_PAIR, state="none", seq=0, bytes=0)


def empty_pub():
    return dict(pc="idle", pair=NULL_PAIR, want="none", delta=0, force=False, events=EventSet(), current=empty_event())


def empty_cb():
    return dict(pc="idle", kind="none", ref="-")


def cb(kind, r="-"):
    return dict(pc="ready", kind=kind, ref=r)


def frames():
    out = {}
    f = inspect.currentframe().f_back
    while f:
        if f.f_code.co_filename.endswith("/download_service.py"):
            out.setdefault(f.f_code.co_name, f.f_locals.copy())
        f = f.f_back
    return out


def atomic():
    return ACTIVE.lock if ACTIVE else contextlib.nullcontext()


def point(hook, values):
    rec = ACTIVE
    if rec is None:
        return
    fs = frames()
    try:
        with rec.lock:
            rec.observe(hook, values, fs)
    except TraceError:
        raise
    except Exception as ex:
        rec.errors.append(f"{hook}: {type(ex).__name__}: {ex}")
        raise TraceError(rec.errors[-1]) from ex
    # Scheduling gates are deliberately outside the recorder/source locks. Only
    # hook points explicitly declared unlocked may be gated by a scenario.
    gate = rec.gates.get(hook)
    if gate:
        gate(values, fs)


def value(hook, result, values):
    point(hook, dict(values, result=result))
    return result


def base_object(ref):
    # Source lock is owned by the fixture Downloadable, as in CacheableObject.
    if ACTIVE is None:
        return ref.obj.base_obj
    with ref.obj.source_lock:
        result = ref.obj.base_obj
        point("base_object", dict(ref=ref, result=result))
        return result


class Recorder:
    def __init__(self, path, action_map, service, tx, waiter, clock, consumer_type, chunk_count=1):
        self.lock = threading.RLock()
        self.path = pathlib.Path(path)
        self.file = self.path.open("w")
        self.map = {a["name"]: a for a in json.loads(pathlib.Path(action_map).read_text())}
        self.service, self.tx, self.waiter, self.clock = service, tx, waiter, clock
        self.late = None
        self.refs = tuple(r.rid for r in tx.refs)
        self.ref_objs = {r.rid: r for r in tx.refs}
        self.sources = {r.rid: r.obj.base_obj for r in tx.refs}
        self.receivers = tuple(tx.receiver_ids)
        self.pairs = tuple((r, c) for r in self.refs for c in self.receivers)
        self.finalizers = (
            tuple(("confirm", *p) for p in self.pairs) + tuple(("cancel", "-", c) for c in self.receivers) + (BUDGET,)
        )
        self.settlers = (INLINE, WORKER)
        self.actors = tuple(("pull", *p) for p in self.pairs) + self.finalizers + self.settlers
        self.nonces = {}
        self.errors, self.gates, self.counts = [], {}, {}
        self.n = 0
        self.s = self.initial_state()
        from nvflare.fuel.f3.streaming import download_service as ds

        assert tx.receiver_ids and tx.num_receivers == len(self.receivers)
        assert consumer_type.supports_pipelining
        assert ds._receiver_confirm_enabled() and tx.progress_cb and tx.progress_interval == 0
        assert tx.transaction_done_cb and tx.outcome_cb and waiter in service._tx_waiters[tx.tid]
        assert not any((r.receiver_statuses or r._pending_confirms or r._receiver_progress) for r in tx.refs)
        assert len(self.sources) == len(tx.refs) and all(v is not None for v in self.sources.values())
        self.config = dict(
            refs=self.refs,
            receivers=self.receivers,
            chunk_count=chunk_count,
            acquire_timeout=int(tx.receiver_acquire_timeout or 0),
            idle_timeout=int(tx.receiver_idle_timeout or 0),
            tx_timeout=int(tx.timeout),
            drain_timeout=int(ds.OP_DRAIN_TIMEOUT),
            receipt_ttl=int(service.TX_OUTCOME_TTL),
            finished_refs_ttl=int(service.FINISHED_REFS_TTL),
            min_receivers=tx.min_receivers,
            receiver_mode="explicit",
            producer_confirm=ds._receiver_confirm_enabled(),
            consumer_confirm=ds._receiver_confirm_enabled(),
            progress_interval=tx.progress_interval,
            progress_enabled=bool(tx.progress_cb),
            pipeline_enabled=bool(consumer_type.supports_pipelining),
            source_profile="owned_release",
            registration_frozen=True,
        )
        self.write(
            dict(
                tag="config",
                ts=REAL_NS(),
                event="init",
                schema=1,
                source_sha=SHA,
                tx=tx.tid,
                config=encode(self.config),
                post=encode(self.s),
            )
        )

    def f(self, domain, value):
        return Fn((k, copy.deepcopy(value)) for k in domain)

    def empty_verdict(self):
        return dict(
            status="none",
            reason="none",
            done="none",
            matrix=self.f(self.pairs, "none"),
            refsPresent=False,
            quorum=False,
        )

    def initial_state(self):
        tx, svc = self.tx, self.service
        s = dict(
            now=self.clock.normalized(),
            live=svc._tx_table.get(tx.tid) is tx,
            owner=svc._outcome_owners.get(tx.tid) is tx,
            closed=tx._ops_closed,
            terminating=svc._terminating_txs.get(tx.tid) is tx,
            settlementComplete=tx._settlement_complete,
            shutdown=False,
            txLast=self.clock.norm(tx.last_active_time),
            acquired=set(tx._acquired_receivers),
            ops=set(),
            tombstoneAt=-1,
            abandoned=set(),
            confirmWire=set(),
            cancelWire=set(),
            finishReady=set(),
            budgetNow=0,
            monitorPC="idle",
            monitorNow=0,
            progressStarted=set(),
            cause="none",
            queued=False,
            submitPC="idle",
            doneCalls=0,
            outcomeCbCalls=0,
            effectsAfterReceipt=False,
            callbackErrors=0,
            receiptWrites=0,
            receipt=self.empty_verdict(),
            retained=tx.tid in svc._tx_outcomes,
            recordAt=0,
            recordedBy=INLINE,
            waiter="pending" if not self.waiter.done() else "none",
            waiterOutcome=self.empty_verdict(),
            lateWaiter="unregistered",
            lateOutcome=self.empty_verdict(),
            caller="waiting",
        )
        for key, val in dict(
            status="none",
            provisional="none",
            pending=False,
            futureStarted=False,
            pullPC="idle",
            pullTime=0,
            index=0,
            rc="none",
            nonce=False,
            reply="none",
            replyNonce=False,
            consumer="new",
            consumerResult="none",
            consumerNonce=False,
            refLast=-1,
            progressTerminal="none",
            progressBytes=0,
            progressSeq=0,
            observedTerminal="none",
        ).items():
            s[key] = self.f(self.pairs, val)
        for key, val in dict(
            allDone=False, progressOrder=(), refTerminal="none", sourceHeld=True, objectDoneCalls=0, releaseAttempts=0
        ).items():
            s[key] = self.f(self.refs, val)
        s["receiverLast"] = Fn(
            (c, self.clock.norm(tx._receiver_last_active[c]) if c in tx._receiver_last_active else -1)
            for c in self.receivers
        )
        s["budgetLast"] = self.f(self.receivers, -1)
        for key, val in dict(fpc="idle", fp=NULL_PAIR, ftodo=set(), fwon=False, faccepted=False, fall=False).items():
            s[key] = self.f(self.finalizers, val)
        s["pub"] = self.f(self.actors, empty_pub())
        s["cb"] = self.f(self.actors, empty_cb())
        for key, val in dict(
            spc="idle",
            drainAt=0,
            drainForced=False,
            todo=set(),
            snapshots=self.f(self.pairs, "none"),
            verdicts=self.empty_verdict(),
            baseObjects=self.f(self.refs, False),
            markerLeaked=False,
        ).items():
            s[key] = self.f(self.settlers, val)
        for r in tx.refs:
            for c in self.receivers:
                p = (r.rid, c)
                s["status"][p] = r.receiver_statuses.get(c, "none")
                pending = r._pending_confirms.get(c)
                s["provisional"][p] = pending[0] if pending else "none"
                s["pending"][p] = pending is not None
                s["refLast"][p] = self.clock.norm(r._receiver_activity[c]) if c in r._receiver_activity else -1
            s["allDone"][r.rid] = r._downloaded_to_all_called
            s["sourceHeld"][r.rid] = r.obj.base_obj is self.sources[r.rid]
        assert tx._active_ops == 0 and self.clock.normalized() == 0
        return s

    def write(self, row):
        self.file.write(json.dumps(row, separators=(",", ":")) + "\n")
        self.file.flush()

    def emit(self, name, **args):
        a = self.map[name]
        assert set(args) == {p[0] for p in a["params"]}, (name, args, a["params"])
        self.n += 1
        self.counts[name] = self.counts.get(name, 0) + 1
        self.write(
            dict(
                tag="trace",
                ts=REAL_NS(),
                tx=self.tx.tid,
                n=self.n,
                event=dict(
                    name=name,
                    nid=args.get("p", ("", "producer"))[1] if "p" in args else "producer",
                    state=encode({f: self.s[f] for f in a["fields"]}),
                    msg=encode(args),
                ),
                thread=dict(id=threading.get_ident(), name=threading.current_thread().name),
            )
        )

    def actor(self, fs):
        if "transaction_done" in fs or "_sync_termination_marker" in fs or "_record_outcome" in fs:
            return getattr(TLS, "settler", INLINE)
        if "_handle_confirm" in fs:
            v = fs["_handle_confirm"]
            return ("confirm", v["rid"], v["requester"])
        if "_handle_cancel" in fs:
            return ("cancel", "-", fs["_handle_cancel"]["requester"])
        if "_monitor_tx" in fs:
            return BUDGET
        if "_handle_download" in fs:
            v = fs["_handle_download"]
            return ("pull", v["rid"], v["requester"])
        if "_do_request" in fs:
            v = fs["_do_request"]
            return ("pull", v["ref_id"], v["cell"].get_fqcn())
        if "_download_object" in fs:
            v = fs["_download_object"]
            return ("pull", v["ref_id"], v["cell"].get_fqcn())
        return getattr(TLS, "settler", INLINE)

    def verdict(self, outcome):
        if outcome is None:
            return self.empty_verdict()
        assert outcome.tx_id == self.tx.tid
        assert outcome.num_receivers == len(self.receivers)
        assert tuple(outcome.receiver_ids) == self.receivers and outcome.min_receivers == self.tx.min_receivers
        matrix = self.f(self.pairs, "none")
        for ref in outcome.refs:
            assert ref.ref_id in self.refs and set(ref.receiver_statuses) <= set(self.receivers)
            for c in self.receivers:
                matrix[(ref.ref_id, c)] = ref.receiver_statuses.get(c, "none")
        return dict(
            status=outcome.status,
            reason=outcome.reason,
            done=outcome.done_status,
            matrix=matrix,
            refsPresent=bool(outcome.refs),
            quorum=outcome.quorum_met,
        )

    def observe_waiter(self, w):
        return ("pending" if not w.done() else "none" if w.outcome is None else "receipt", self.verdict(w.outcome))

    def ref_status(self, ref):
        for c in self.receivers:
            p = (ref.rid, c)
            pending = ref._pending_confirms.get(c)
            self.s["status"][p] = ref.receiver_statuses.get(c, "none")
            self.s["pending"][p] = pending is not None
            self.s["provisional"][p] = pending[0] if pending else "none"
        self.s["allDone"][ref.rid] = ref._downloaded_to_all_called

    def progress(self, ref, events):
        s = self.s
        s["progressOrder"][ref.rid] = tuple(ref._receiver_progress)
        for c, pr in ref._receiver_progress.items():
            p = (ref.rid, c)
            if pr.started:
                s["progressStarted"].add(p)
            s["progressBytes"][p] = pr.bytes_done
            s["progressSeq"][p] = pr.sequence
            for e in events:
                if e and e["receiver_id"] == c and e["state"] in TERMINAL:
                    s["progressTerminal"][p] = e["state"]
            assert pr.terminal == (s["progressTerminal"][p] != "none")

    def event(self, e):
        return dict(pair=(e["ref_id"], e["receiver_id"]), state=e["state"], seq=e["sequence"], bytes=e["bytes_done"])

    def request_pub(self, t, ref, c, state, delta, force):
        self.s["pub"][t] = dict(empty_pub(), pc="make", pair=(ref.rid, c), want=state, delta=delta, force=force)

    def nonce_matches(self, p, n):
        if n is None:
            return False
        assert p in self.nonces and self.nonces[p] == n, "nonce not bound to this actual serve"
        return True

    def observe(self, h, v, fs):
        s = self.s
        tx = self.tx
        svc = self.service
        t = self.actor(fs)
        if "cls" in v and v["cls"] is not svc:
            return
        p = tuple(t[1:]) if t[0] in ("pull", "confirm") else None
        hd = fs.get("_handle_download", {})
        co = fs.get("_download_object", {})
        ref = v.get("self") if hasattr(v.get("self"), "rid") else v.get("ref")
        if h == "op_begin":
            if v["self"] is not tx:
                return
            s["ops"].add(t)
            assert len(s["ops"]) == tx._active_ops
            if t[0] == "pull":
                s["pullPC"][p] = "markTx"
                self.emit("HandleDownloadBegin", p=p)
            elif t[0] == "confirm":
                s["confirmWire"].remove(p)
                s["ftodo"][t] = {p}
                s["fpc"][t] = "select"
                self.emit("HandleConfirmBegin", p=p)
            elif t[0] == "cancel":
                s["cancelWire"].remove(t[2])
                s["fpc"][t] = "acquired"
                self.emit("HandleCancelBegin", c=t[2])
            else:
                s["fpc"][BUDGET] = "snapshot"
                s["monitorPC"] = "budget"
                self.emit("MonitorAdmitBudgets")
        elif h == "op_end":
            if v["self"] is not tx:
                return
            s["ops"].remove(t)
            assert len(s["ops"]) == tx._active_ops
            if t[0] == "pull":
                result = TLS.producer_reply
                s["pullPC"][p] = "done"
                s["reply"][p] = self.reply_rc(result)
                s["replyNonce"][p] = self.nonce_matches(p, (result.payload or {}).get("confirm_nonce"))
                self.emit("HandleDownloadEndOp", p=p)
            elif t == BUDGET:
                s["fpc"][t] = "idle"
                s["monitorPC"] = "classify"
                self.emit("MonitorBudgetEndOp")
            else:
                s["fpc"][t] = "done"
                # The actual return accumulated by the caller, never a guessed winner.
                fv = fs["_handle_confirm" if t[0] == "confirm" else "_handle_cancel"]
                if fv["accepted"]:
                    s["finishReady"].add(t)
                self.emit("FinalizerEndOp", t=t)
        elif h == "mark_active":
            if v["self"] is not tx:
                return
            s["txLast"] = self.clock.norm(tx.last_active_time)
            if t[0] == "pull":
                s["pullPC"][p] = "markRef"
                self.emit("HandleDownloadMarkActive", p=p)
            elif t[0] == "confirm":
                s["fpc"][t] = "end"
                self.emit("HandleConfirmMarkActive", p=p)
        elif h == "ref_active":
            p = (ref.rid, v["receiver"])
            s["pullTime"][p] = self.clock.norm(v["now"])
            s["refLast"][p] = self.clock.norm(ref._receiver_activity[p[1]])
            s["pullPC"][p] = "markReceiver"
            self.emit("RefMarkReceiverActive", p=p)
        elif h == "tx_receiver_active":
            p = (ref.rid, v["receiver"])
            s["receiverLast"][p[1]] = self.clock.norm(tx._receiver_last_active[p[1]])
            s["acquired"] = set(tx._acquired_receivers)
            s["pullPC"][p] = "startProgress"
            self.emit("TransactionMarkReceiverActive", p=p)
        elif h == "request_start":
            # At the real request worker entry, before Cell admission. First request
            # is synchronous; subsequent ones run on the real download executor.
            if p not in self.pairs:
                return
            if v["req_state"] is None:
                assert s["consumer"][p] == "new"
                assert co["pipeline_enabled"] and co["confirm_enabled"]
                s["consumer"][p] = "waiting"
                s["futureStarted"][p] = True
                s["pullPC"][p] = "sent"
                self.emit("DownloadObjectStart", p=p)
            else:
                s["futureStarted"][p] = True
                self.emit("DownloadRequestWorkerStart", p=p)
        elif h == "produce":
            s["rc"][p] = {"ok": "data", "eof": "eof", "error": "error"}[v["rc"]]
            s["pullPC"][p] = "dataProgress" if v["rc"] == "ok" else "served"
            self.emit("HandleDownloadProduceError" if v["rc"] == "error" else "HandleDownloadProduce", p=p)
        elif h == "produce_exception":
            TLS.produce_exception = True
        elif h in ("served", "served_final"):
            p = (ref.rid, v["to_receiver"])
            self.ref_status(ref)
            n = v["nonce"] if h == "served" else None
            if n:
                self.nonces[p] = n
            s["nonce"][p] = self.nonce_matches(p, n)
            s["pullPC"][p] = "terminalProgress"
            self.emit("RefObjServed", p=p)
        elif h == "progress_request":
            c = v["receiver_id"]
            state = v["state"]
            delta = v["bytes_delta"]
            force = v["force"]
            self.request_pub(t, ref, c, state, delta, force)
            if t[0] == "pull":
                if getattr(TLS, "produce_exception", False):
                    TLS.produce_exception = False
                    s["rc"][p] = "exception"
                    s["pullPC"][p] = "end"
                    self.emit("HandleDownloadProduceException", p=p)
                elif "rc" not in hd:
                    s["pullPC"][p] = "produce"
                    self.emit("HandleDownloadActiveProgress", p=p)
                elif hd["rc"] == "ok":
                    assert delta == 1
                    s["nonce"][p] = False
                    s["pullPC"][p] = "end"
                    self.emit("HandleDownloadDataProgress", p=p)
                else:
                    s["pullPC"][p] = "end"
                    self.emit("HandleDownloadTerminalProgress", p=p)
            else:
                s["fpc"][t] = "advance"
                self.emit("RefFinalizerProgress", t=t)
        elif h == "progress_made":
            event = v["event"]
            self.progress(ref, [event])
            s["pub"][t]["events"] = EventSet([self.event(event)]) if event else EventSet()
            s["pub"][t]["pc"] = "call" if event else "idle"
            self.emit("RefMakeProgressEvent", t=t)
        elif h == "progress_callback":
            e = self.event(v["event"])
            pub = s["pub"][t]
            pub["events"].remove(e)
            pub["current"] = e
            pub["pc"] = "return"
            if e["state"] in TERMINAL:
                s["observedTerminal"][e["pair"]] = e["state"]
            self.emit("TransactionEmitProgressEvent", t=t, e=e)
        elif h == "progress_returned":
            pub = s["pub"][t]
            pub["pc"] = "call" if pub["events"] else "idle"
            pub["current"] = empty_event()
            self.emit("TransactionProgressCallbackReturn", t=t)
        elif h == "producer_reply":
            if hd.get("confirm_status") is not None or hd.get("payload", {}).get("cancel"):
                return
            p = (hd["rid"], hd["requester"])
            if p not in self.pairs:
                return
            TLS.producer_reply = v["result"]
            if v.get("ref") is None:
                s["pullPC"][p] = "done"
                s["reply"][p] = self.reply_rc(v["result"])
                s["replyNonce"][p] = False
                self.emit("HandleDownloadMissing", p=p)
        elif h == "consumer_data":
            assert v["data"] == b"x" and v["producer_accepts_cancel"]
            s["reply"][p] = "none"
            s["index"][p] = v["state"]["chunk_idx"]
            s["consumer"][p] = "data"
            self.emit("ConsumerReceiveData", p=p)
        elif h == "pipeline_submit":
            s["consumer"][p] = "consuming"
            s["futureStarted"][p] = False
            s["pullPC"][p] = "sent"
            self.emit("ConsumerLaunchPipeline", p=p)
        elif h == "consumer_consume_return":
            assert v["new_state"] == v["request_state"]
            s["consumer"][p] = "waiting"
            self.emit("ConsumerConsumeReturn", p=p)
        elif h in ("consumer_eof", "consumer_producer_error"):
            s["reply"][p] = "none"
            s["consumerNonce"][p] = self.nonce_matches(p, v["confirm_nonce"])
            s["consumer"][p] = "completing" if h == "consumer_eof" else "confirmReady"
            if h == "consumer_producer_error":
                s["consumerResult"][p] = "failed"
            self.emit("ConsumerReceiveEOF" if h == "consumer_eof" else "ConsumerReceiveProducerError", p=p)
        elif h in ("consumer_completed", "consumer_completed_exception"):
            s["consumerResult"][p] = "success" if h == "consumer_completed" else "failed"
            s["consumer"][p] = "confirmReady"
            self.emit(
                "ConsumerDownloadCompleted" if h == "consumer_completed" else "ConsumerDownloadCompletedException", p=p
            )
        elif h in ("confirm_skip", "control_message"):
            if h == "control_message":
                payload = v["result"].payload
                assert payload["ref_id"] == p[0] and co["from_fqcn"] == "server"
                if payload.get("cancel") is True:
                    assert p[1] in s["cancelWire"]
                    return
                assert payload["confirm"] == s["consumerResult"][p]
                assert self.nonce_matches(p, payload["confirm_nonce"])
            if co["confirm_enabled"] and co["producer_expects_confirm"]:
                assert self.nonce_matches(p, co["confirm_nonce"]) and v["receiver_truth"] == s["consumerResult"][p]
                s["confirmWire"].add(p)
            s["consumer"][p] = "done"
            self.emit("ConsumerSendConfirm", p=p)
        elif h == "confirm_lost":
            s["confirmWire"].remove(p)
            self.emit("LoseConfirmation", p=p)
        elif h in ("consumer_consume_exception", "consumer_request_error"):
            s["consumer"][p] = "failed"
            s["consumerResult"][p] = "failed"
            s["abandoned"].add(p[1])
            if v["producer_accepts_cancel"]:
                s["cancelWire"].add(p[1])
            if h == "consumer_consume_exception":
                future = v["pending_future"]
                if future and future.cancelled():
                    s["pullPC"][p] = "done"
                self.emit("ConsumerConsumeException", p=p)
            else:
                s["reply"][p] = "none"
                self.emit("ConsumerReceiveError", p=p)
        elif h == "confirm_late":
            s["confirmWire"].remove(p)
            self.emit("HandleConfirmLate", p=p)
        elif h == "cancel_late":
            s["cancelWire"].remove(t[2])
            self.emit("HandleCancelLate", c=t[2])
        elif h == "cancel_acquired":
            s["ftodo"][t] = {(r, t[2]) for r in self.refs} if v["acquired"] else set()
            s["fpc"][t] = "select"
            self.emit("HandleCancelAcquired", c=t[2])
        elif h == "finalizer_select":
            if "_finalize_receiver" not in fs:
                return
            if t == BUDGET:
                return  # candidate already selected before stats-lock recheck
            p = (ref.rid, v["to_receiver"])
            s["fp"][t] = p
            s["ftodo"][t].remove(p)
            s["fpc"][t] = "commit"
            self.emit("FinalizerSelectRef", t=t, p=p)
        elif h in ("finalizer_commit", "finalizer_reject"):
            p = (ref.rid, v["to_receiver"])
            self.ref_status(ref)
            won = h == "finalizer_commit"
            s["fwon"][t] = won
            s["faccepted"][t] = s["faccepted"][t] or won
            s["fall"][t] = bool(v.get("all_done", False)) if won else False
            if won:
                s["cb"][t] = cb("one", ref.rid)
            s["fpc"][t] = "one" if won else "advance"
            self.emit("RefFinalizeReceiverCommit", t=t)
        elif h == "one_returned":
            s["cb"][t] = cb("all", ref.rid) if v["all_done"] else empty_cb()
            s["fpc"][t] = "all" if v["all_done"] else "progress"
            self.emit("RefDownloadedToOneReturned", t=t)
        elif h == "all_returned":
            s["cb"][t] = empty_cb()
            s["fpc"][t] = "progress"
            self.emit("RefDownloadedToAllReturned", t=t)
        elif h in ("finalizer_advance", "budget_advance"):
            s["fpc"][t] = "select"
            self.emit("FinalizerAdvance", t=t)
        elif h == "confirm_inactive":
            s["fpc"][t] = "end"
            self.emit("HandleConfirmMarkActive", p=p)
        elif h == "cancel_loop_done":
            s["fpc"][t] = "end"
            self.emit("HandleCancelLoopDone", c=t[2])
        elif h == "monitor_begin":
            if not s["live"]:
                return
            s["monitorNow"] = self.clock.norm(v["now"])
            s["monitorPC"] = "admit"
            self.emit("MonitorBegin")
        elif h in ("monitor_no_budgets", "monitor_admission_failed"):
            if s["monitorPC"] != "admit":
                return
            if h == "monitor_no_budgets" and tx in v["budget_txs"]:
                return
            s["monitorPC"] = "classify"
            self.emit("MonitorAdmitBudgets")
        elif h == "budget_snapshot":
            s["budgetLast"] = Fn(
                (c, self.clock.norm(v["tx_last_active"][c]) if c in v["tx_last_active"] else -1) for c in self.receivers
            )
            s["budgetNow"] = self.clock.norm(v["now"])
            s["faccepted"][BUDGET] = False
            s["ftodo"][BUDGET] = set(self.pairs)
            s["fpc"][BUDGET] = "select"
            self.emit("EnforceReceiverBudgetsSnapshot")
        elif h == "budget_nonfailures":
            failures = {x[0] for x in v["failures"]}
            for c in v["candidates"]:
                if c not in failures:
                    self.budget_select(ref, c, False)
        elif h == "budget_select":
            self.budget_select(ref, v["receiver"], True)
        elif h == "budget_recheck":
            fresh = tx._receiver_last_active.get(v["receiver"]) == v["tx_last_active"].get(v["receiver"])
            s["fpc"][BUDGET] = "commit" if fresh else "select"
            self.emit("RefEnforceBudgetRecheck")
        elif h in ("finish", "delete", "monitor_timeout", "monitor_finished"):
            s["live"] = svc._tx_table.get(tx.tid) is tx
            s["terminating"] = svc._terminating_txs.get(tx.tid) is tx
            s["cause"] = {
                "finish": "finished",
                "delete": "deleted",
                "monitor_timeout": "timeout",
                "monitor_finished": "finished",
            }[h]
            if h in ("finish", "monitor_finished"):
                stamps = {svc._finished_refs[r].last_active_time for r in self.refs}
                assert len(stamps) == 1
                s["tombstoneAt"] = self.clock.norm(stamps.pop())
            if h == "finish":
                s["finishReady"].remove(t)
                s["submitPC"] = "ready"
                self.emit("FinishTransactionIfComplete", t=t)
            else:
                s["spc"][INLINE] = "enter"
                if h.startswith("monitor"):
                    s["monitorPC"] = "settling"
                self.emit(
                    {
                        "delete": "DeleteTransaction",
                        "monitor_timeout": "MonitorRetireTimeout",
                        "monitor_finished": "MonitorRetireFinished",
                    }[h]
                )
        elif h in ("finish_missing", "finish_scan_missing"):
            if h == "finish_scan_missing" and "_finish_transaction_if_complete" not in fs:
                return
            if t in s["finishReady"]:
                s["finishReady"].remove(t)
                self.emit("FinishTransactionNotComplete", t=t)
        elif h == "monitor_not_retired":
            if s["monitorPC"] == "classify":
                s["monitorPC"] = "idle"
                self.emit("MonitorNoRetirement")
        elif h == "submit_return":
            if v["future"] is None:
                s["submitPC"] = "fallback"
                self.emit("CheckedExecutorSubmitStopped")
            else:
                s["submitPC"] = "done"
                self.emit("CheckedExecutorSubmitReturn")
        elif h == "submit_exception":
            s["submitPC"] = "fallback"
            self.emit("CheckedExecutorSubmitRuntimeError")
        elif h == "submit_fallback":
            s["submitPC"] = "done"
            s["spc"][INLINE] = "enter"
            self.emit("SubmitFinishedSettlementFallback")
        elif h == "drain_begin":
            s["closed"] = tx._ops_closed
            s["drainAt"][t] = self.clock.norm(v["deadline"] - v["timeout"])
            s["spc"][t] = "drain"
            self.emit("TransactionDoneDrainBegin", t=t)
        elif h in ("drain_empty", "drain_expired"):
            s["spc"][t] = "snapshot"
            s["todo"][t] = set(r.rid for r in tx.snapshot_refs())
            if h == "drain_expired":
                s["drainForced"][t] = True
            self.emit("TransactionDoneDrainEmpty" if h == "drain_empty" else "TransactionDoneDrainExpired", t=t)
        elif h == "snapshot_ref":
            if "transaction_done" not in fs:
                return
            for c in self.receivers:
                s["snapshots"][t][(ref.rid, c)] = v["result"].get(c, "none")
            s["todo"][t].remove(ref.rid)
            self.emit("TransactionDoneSnapshotRef", t=t, r=ref.rid)
        elif h == "computed":
            s["verdicts"][t] = self.verdict(v["outcome"])
            s["spc"][t] = "terminalProgress"
            s["todo"][t] = set(r.rid for r in v["refs"])
            self.emit(
                (
                    "TransactionDoneComputeException"
                    if v["outcome"].reason == "computation_failed"
                    else "TransactionDoneComputeOutcome"
                ),
                t=t,
            )
        elif h == "terminal_batch":
            self.progress(ref, v["events"])
            s["refTerminal"][ref.rid] = ref._terminal_progress_state
            es = EventSet(self.event(e) for e in v["events"] if e)
            s["pub"][t] = dict(empty_pub(), pc="call" if es else "idle", events=es)
            s["todo"][t].remove(ref.rid)
            self.emit("TransactionDoneTerminalProgress", t=t, r=ref.rid)
        elif h == "settlement_progress_returned":
            s["spc"][t] = "baseObjects"
            s["todo"][t] = set(r.rid for r in v["refs"])
            self.emit("TransactionDoneProgressReturned", t=t)
        elif h == "base_object":
            r = v["ref"].rid
            s["baseObjects"][t][r] = v["result"] is self.sources[r]
            s["todo"][t].remove(r)
            self.emit("TransactionDoneSnapshotBaseObject", t=t, r=r)
        elif h == "objects_begin":
            s["spc"][t] = "objects"
            s["todo"][t] = set(r.rid for r in v["refs"])
            self.emit("TransactionDoneObjectsBegin", t=t)
        elif h == "object_callback":
            r = ref.rid
            s["cb"][t] = cb("objectDone", r)
            s["todo"][t].remove(r)
            self.emit("TransactionDoneObjectCallback", t=t, r=r)
        elif h == "object_returned":
            s["cb"][t] = empty_cb()
            self.emit("TransactionDoneObjectReturned", t=t)
        elif h == "tx_callback":
            s["cb"][t] = cb("txDone")
            s["spc"][t] = "txCallback"
            self.emit("TransactionDoneTransactionCallback", t=t)
        elif h == "outcome_callback":
            s["cb"][t] = cb("outcome")
            s["spc"][t] = "outcomeCallback"
            self.emit("TransactionDoneOutcomeCallback", t=t)
        elif h == "release_begin":
            s["cb"][t] = empty_cb()
            s["spc"][t] = "release"
            s["todo"][t] = set(r.rid for r in v["refs"])
            self.emit("TransactionDoneReleaseBegin", t=t)
        elif h == "release_callback":
            r = ref.rid
            s["cb"][t] = cb("release", r)
            s["todo"][t].remove(r)
            self.emit("TransactionDoneRelease", t=t, r=r)
        elif h == "release_returned":
            s["cb"][t] = empty_cb()
            self.emit("TransactionDoneReleaseReturned", t=t)
        elif h in ("callback_enter", "callback_return", "callback_exception"):
            # on_outcome recording is infrastructure, not a modeled lifecycle hook.
            if v["what"].startswith("outcome recording"):
                return
            if h == "callback_enter":
                kind = s["cb"][t]["kind"]
                r = s["cb"][t]["ref"]
                args = v["args"]
                if kind == "one":
                    arg = dict(receiver=args[0], status=args[1])
                elif kind in ("all", "release"):
                    assert args == ()
                    arg = ()
                elif kind == "objectDone":
                    assert args[0] == tx.tid
                    arg = dict(tx="tx", status=args[1])
                    s["objectDoneCalls"][r] += 1
                elif kind == "txDone":
                    assert args[0] == tx.tid
                    arg = dict(
                        tx="tx",
                        status=args[1],
                        sources=Fn((r, obj is self.sources[r]) for r, obj in zip(self.refs, args[2], strict=True)),
                    )
                    s["doneCalls"] += 1
                elif kind == "outcome":
                    arg = self.verdict(args[0])
                    s["outcomeCbCalls"] += 1
                else:
                    raise AssertionError(("unknown callback", v["what"], kind))
                if kind == "release":
                    s["releaseAttempts"][r] += 1
                if kind in ("objectDone", "txDone", "outcome", "release") and (
                    self.waiter.done()
                    and self.waiter.outcome is not None
                    or self.late
                    and self.late.done()
                    and self.late.outcome is not None
                ):
                    s["effectsAfterReceipt"] = True
                s["cb"][t]["pc"] = "running"
                self.emit("InvokeCallbackSafely", t=t, arg=arg)
            else:
                s["cb"][t]["pc"] = "done"
                if h == "callback_exception":
                    s["callbackErrors"] += 1
                self.emit("CallbackReturn" if h == "callback_return" else "CallbackException", t=t)
        elif h == "source_released":
            r = v["self"].ref_id
            s["sourceHeld"][r] = v["self"].base_obj is self.sources[r]
            s["cb"][t]["pc"] = "releaseReturn"
            self.emit("ReleaseSourceReference", t=t)
        elif h == "record_ready":
            s["spc"][t] = "record"
            self.emit("TransactionDoneRecordReady", t=t)
        elif h in ("record_drop", "record_skipped"):
            s["spc"][t] = "complete"
            self.emit("RecordOutcomeDrop", t=t)
        elif h == "record":
            s["owner"] = svc._outcome_owners.get(tx.tid) is tx
            s["receiptWrites"] += 1
            s["receipt"] = self.verdict(svc._tx_outcomes[tx.tid])
            s["retained"] = tx.tid in svc._tx_outcomes
            s["recordAt"] = self.clock.norm(v["outcome"].timestamp)
            s["recordedBy"] = t
            s["spc"][t] = "complete"
            s["waiter"], s["waiterOutcome"] = self.observe_waiter(self.waiter)
            if self.late:
                s["lateWaiter"], s["lateOutcome"] = self.observe_waiter(self.late)
            self.emit("RecordOutcome", t=t)
        elif h == "settlement_complete":
            s["settlementComplete"] = tx._settlement_complete
            s["spc"][t] = "markerRead"
            self.emit("TransactionDoneComplete", t=t)
        elif h == "marker_read":
            s["markerLeaked"][t] = v["leaked"]
            s["spc"][t] = "markerWrite"
            self.emit("SyncTerminationMarkerRead", t=t)
        elif h == "marker_write":
            s["terminating"] = svc._terminating_txs.get(tx.tid) is tx
            s["spc"][t] = "done"
            self.emit("SyncTerminationMarkerWrite", t=t)
        elif h == "marker_reap":
            if v["tid"] == tx.tid:
                s["terminating"] = tx.tid in svc._terminating_txs
                self.emit("ReapTerminationMarker")
        elif h == "late_waiter":
            if v["transaction_id"] != tx.tid:
                return
            assert self.late is None
            self.late = v["waiter"]
            s["lateWaiter"], s["lateOutcome"] = self.observe_waiter(self.late)
            self.emit("GetTransferWaiter")
        elif h == "expire":
            if v["tid"] == tx.tid:
                s["retained"] = tx.tid in svc._tx_outcomes
                self.emit("ExpireOutcome")
        elif h == "shutdown":
            s["shutdown"] = True
            s["live"] = svc._tx_table.get(tx.tid) is tx
            s["owner"] = svc._outcome_owners.get(tx.tid) is tx
            s["retained"] = tx.tid in svc._tx_outcomes
            s["terminating"] = svc._terminating_txs.get(tx.tid) is tx
            if tx in v["tx_list"]:
                s["cause"] = "deleted"
                s["spc"][INLINE] = "enter"
            s["waiter"] = self.observe_waiter(self.waiter)[0]
            if self.late:
                s["lateWaiter"] = self.observe_waiter(self.late)[0]
            self.emit("Shutdown")
        elif h == "caller_success":
            s["caller"] = "success"
            self.emit("WaitForResultTransfers")
        elif h == "caller_error":
            s["caller"] = "error"
            self.emit("WaitForResultTransfers")
        elif h == "advance_time":
            s["now"] = self.clock.normalized()
            self.emit("AdvanceTime")
        else:
            raise AssertionError(("unhandled hook", h))

    def budget_select(self, ref, c, eligible):
        p = (ref.rid, c)
        s = self.s
        s["fp"][BUDGET] = p
        s["ftodo"][BUDGET].remove(p)
        s["fpc"][BUDGET] = "recheck" if eligible else "select"
        self.emit("RefEnforceBudgetSelect", p=p)

    @staticmethod
    def reply_rc(reply):
        from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode

        rc = reply.get_header(MessageHeaderKey.RETURN_CODE)
        if rc == ReturnCode.PROCESS_EXCEPTION:
            return "exception"
        if rc != ReturnCode.OK:
            return "missing"
        return {"ok": "data", "eof": "eof", "error": "error"}[reply.payload["status"]]

    def close(self):
        self.file.close()
        assert not self.errors, self.errors


class QueueProbe:
    """Proxy only a dedicated CheckedExecutor's original SimpleQueue."""

    def __init__(self, queue, recorder):
        self.queue, self.recorder = queue, recorder

    @staticmethod
    def selected(item):
        if item is None:
            return False
        task = getattr(item, "task", None)
        fn = task[0] if task else getattr(item, "fn", None)
        return getattr(fn, "__name__", None) == "_settle_finished_transaction"

    def put(self, item, *args, **kwargs):
        if not self.selected(item):
            return self.queue.put(item, *args, **kwargs)
        with self.recorder.lock:
            result = self.queue.put(item, *args, **kwargs)
            self.recorder.s["queued"] = True
            self.recorder.s["submitPC"] = "enqueued"
            self.recorder.emit("CheckedExecutorEnqueue")
            return result

    def get(self, *args, **kwargs):
        item = self.queue.get(*args, **kwargs)
        if self.selected(item):
            TLS.settler = WORKER
            with self.recorder.lock:
                self.recorder.s["queued"] = False
                self.recorder.s["spc"][WORKER] = "enter"
                self.recorder.emit("SettleFinishedTransactionWorker")
        return item

    def get_nowait(self):
        return self.get(block=False)

    def empty(self):
        return self.queue.empty()

    def qsize(self):
        return self.queue.qsize()


def caller_observed(fn):
    import functools

    @functools.wraps(fn)
    def wrapped(*args, **kwargs):
        try:
            result = fn(*args, **kwargs)
        except Exception:
            point("caller_error", {})
            raise
        point("caller_success", {})
        return result

    return wrapped
