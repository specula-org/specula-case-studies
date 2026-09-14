# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
"""Real Cell + Consumer + DownloadService functional trace scenarios.

Reuses upstream MockDownloadable's ordinary produce implementation and isolated
service helper; replaces its release with an owned-reference implementation.
The protocol methods are never mocked. Cell in-process delivery may bypass TCP.
"""

import concurrent.futures
import os
import pathlib
import threading
import time
from types import SimpleNamespace

import pytest

from nvflare.fuel.f3.cellnet.cell import Cell
from nvflare.fuel.f3.cellnet.core_cell import CoreCell
from nvflare.fuel.f3.streaming import download_service as ds
from nvflare.fuel.f3.streaming import specula_trace as trace
from nvflare.fuel.f3.streaming.stream_utils import CheckedExecutor
from nvflare.fuel.utils.network_utils import get_open_ports
from tests.unit_test.fuel.f3.streaming.download_test_utils import MockDownloadable, make_isolated_download_service

OUTPUT = pathlib.Path(__file__).resolve().parents[2]
REAL_TIME = time.time
REAL_SLEEP = time.sleep


class MonitorIterationDone(Exception):
    pass


class Clock:
    monotonic = staticmethod(time.monotonic)

    def __init__(self):
        self.origin = int(REAL_TIME())
        self.tick = 0
        self.monitor_thread = None

    def time(self):
        return self.origin + self.tick

    def norm(self, x):
        n = x - self.origin
        assert int(n) == n, (x, self.origin)
        return int(n)

    def normalized(self):
        return self.tick

    def sleep(self, seconds):
        if threading.get_ident() == self.monitor_thread:
            raise MonitorIterationDone
        REAL_SLEEP(seconds)

    def advance(self, steps):
        for _ in range(steps):
            with trace.atomic():
                self.tick += 1
                trace.point("advance_time", {})

    def monitor(self, service):
        self.monitor_thread = threading.get_ident()
        try:
            with pytest.raises(MonitorIterationDone):
                service._monitor_tx()
        finally:
            self.monitor_thread = None


class OwnedSource(MockDownloadable):
    def __init__(self, *, errors=()):
        super().__init__([b"x"])
        self.source_lock = threading.RLock()
        self.errors = set(errors)
        self.terminal_gate = None
        self.terminal_entered = threading.Event()

    def produce(self, state, requester):
        if state and state["chunk_idx"] == 1 and self.terminal_gate:
            self.terminal_entered.set()
            assert self.terminal_gate.wait(15), "producer gate did not open"
        if "produce" in self.errors and state:
            raise RuntimeError("ordinary source read failure")
        return super().produce(state, requester)

    def downloaded_to_one(self, to_receiver, status):
        super().downloaded_to_one(to_receiver, status)
        if "one" in self.errors:
            raise RuntimeError("ordinary one callback failure")

    def downloaded_to_all(self):
        super().downloaded_to_all()
        if "all" in self.errors:
            raise RuntimeError("ordinary all callback failure")

    def transaction_done(self, transaction_id, status):
        super().transaction_done(transaction_id, status)
        if "objectDone" in self.errors:
            raise RuntimeError("ordinary object callback failure")

    def release(self):
        if "release" in self.errors:
            raise RuntimeError("ordinary release failure before mutation")
        with self.source_lock:
            self.base_obj = None
            trace.point("source_released", locals())
        self.released = True


class ByteConsumer(ds.Consumer):
    supports_pipelining = True

    def __init__(self, *, fail_complete=False, fail_consume=False):
        super().__init__()
        self.fail_complete = fail_complete
        self.fail_consume = fail_consume
        self.data = []
        self.failed = []
        self.completed = False
        self.complete_entered = threading.Event()
        self.complete_gate = None
        self.consume_entered = threading.Event()
        self.consume_gate = None

    def consume(self, ref_id, state, data):
        self.consume_entered.set()
        if self.consume_gate:
            assert self.consume_gate.wait(15)
        if self.fail_consume:
            raise RuntimeError("ordinary receiver consume failure")
        self.data.append(data)
        return dict(state)

    def download_completed(self, ref_id):
        self.complete_entered.set()
        if self.complete_gate:
            assert self.complete_gate.wait(15)
        if self.fail_complete:
            raise RuntimeError("ordinary receiver finalize failure")
        self.completed = True

    def download_failed(self, ref_id, reason):
        self.failed.append(reason)


class Session:
    def __init__(self, monkeypatch, name, *, acquire=3, idle=3, timeout=10, errors=()):
        self.clock = Clock()
        monkeypatch.setattr(ds, "time", self.clock)
        monkeypatch.setattr(ds, "OP_DRAIN_TIMEOUT", 2.0)
        monkeypatch.setattr(ds, "_receiver_confirm_cached", True)
        self.service = make_isolated_download_service()
        monkeypatch.setattr(ds, "DownloadService", self.service)
        # Reuse upstream no-monitor convention; drive the real loop synchronously.
        self.service._tx_monitor = object()
        self.service.TX_OUTCOME_TTL = 4
        self.service.FINISHED_REFS_TTL = 9
        port = get_open_ports(1)[0]
        url = f"tcp://127.0.0.1:{port}"
        self.cells = [Cell(n, url, secure=False, credentials={}) for n in ("server", "site-a", "site-b")]
        for cell in self.cells:
            cell.core_cell.start()
        self.server = self.cells[0]
        self.pool = CheckedExecutor(4, "trace_settle")
        self.download_pool = CheckedExecutor(4, "trace_pull")
        monkeypatch.setattr(ds, "callback_thread_pool", self.pool)
        monkeypatch.setattr(ds, "download_request_thread_pool", self.download_pool)
        self.progress = []
        self.outcomes = []
        self.done = []

        def done(tid, status, objects):
            self.done.append((tid, status, objects))
            if "txDone" in errors:
                raise RuntimeError("ordinary transaction callback failure")

        def outcome(o):
            self.outcomes.append(o)
            if "outcome" in errors:
                raise RuntimeError("ordinary outcome callback failure")

        self.tid = self.service.new_transaction(
            cell=self.server,
            timeout=timeout,
            num_receivers=2,
            receiver_ids=["site-a", "site-b"],
            min_receivers=1,
            progress_cb=lambda **e: self.progress.append(e),
            progress_interval=0,
            transaction_done_cb=done,
            outcome_cb=outcome,
            receiver_acquire_timeout=acquire,
            receiver_idle_timeout=idle,
        )
        self.sources = [OwnedSource(errors=errors), OwnedSource()]
        self.rids = [self.service.add_object(self.tid, s) for s in self.sources]
        self.tx = self.service._tx_table[self.tid]
        self.waiter = self.service.get_transfer_waiter(self.tid)
        self.rec = trace.Recorder(
            OUTPUT / "traces" / f"{name}.ndjson",
            OUTPUT / "spec/action-map.json",
            self.service,
            self.tx,
            self.waiter,
            self.clock,
            ByteConsumer,
        )
        self.pool._work_queue = trace.QueueProbe(self.pool._work_queue, self.rec)
        trace.ACTIVE = self.rec
        self.background = concurrent.futures.ThreadPoolExecutor(4, thread_name_prefix="receiver")
        self.futures = []

    def download(self, ref_index, receiver, consumer=None):
        consumer = consumer or ByteConsumer()
        ds.download_object(
            "server", self.rids[ref_index], 5, self.cells[1 if receiver == "site-a" else 2], consumer, max_retries=0
        )
        return consumer

    def launch(self, *args):
        f = self.background.submit(self.download, *args)
        self.futures.append(f)
        return f

    def await_settlement(self):
        assert self.waiter.wait(10) is not None
        deadline = time.monotonic() + 10
        while self.tid in self.service._terminating_txs and time.monotonic() < deadline:
            REAL_SLEEP(0.005)
        assert self.tx._settlement_complete
        assert self.tid not in self.service._terminating_txs
        return self.waiter.outcome

    def caller(self, success):
        from nvflare.client.cell.api import CellClientAPI, TrainerSessionError

        obj = SimpleNamespace(_abort=False, _closed=False)
        if success:
            CellClientAPI._wait_for_result_transfers(obj, [self.waiter])
        else:
            with pytest.raises(TrainerSessionError):
                CellClientAPI._wait_for_result_transfers(obj, [self.waiter])

    def close(self):
        self.background.shutdown(wait=True)
        self.download_pool.shutdown(wait=True)
        self.pool.shutdown(wait=True)
        trace.ACTIVE = None
        self.service.shutdown()
        for cell in reversed(self.cells):
            cell.core_cell.stop()
            CoreCell.ALL_CELLS.pop(cell.get_fqcn(), None)
        self.rec.close()


@pytest.fixture
def session(monkeypatch, request):
    sessions = []

    def create(**kwargs):
        s = Session(monkeypatch, request.node.name.removeprefix("test_"), **kwargs)
        sessions.append(s)
        return s

    yield create
    for s in reversed(sessions):
        s.close()


def test_confirmed_success(session):
    s = session()
    blocked = ByteConsumer()
    blocked.complete_gate = threading.Event()
    first = s.launch(0, "site-a", blocked)
    if not blocked.complete_entered.wait(10):
        first.result(1)
        pytest.fail("completion gate not reached")
    ref = s.tx.refs[0]
    assert ref.receiver_statuses == {} and ref.snapshot_pending_confirms() == {"site-a": "success"}
    assert not s.waiter.done() and all(x.base_obj is not None for x in s.sources)
    blocked.complete_gate.set()
    first.result(10)
    for i, c in [(1, "site-a"), (0, "site-b"), (1, "site-b")]:
        s.launch(i, c)
    for f in s.futures:
        f.result(10)
    o = s.await_settlement()
    assert o.completed and o.quorum_met
    assert all(x.released for x in s.sources) and len(s.done) == len(s.outcomes) == 1
    late = s.service.get_transfer_waiter(s.tid)
    assert late.outcome == o
    s.caller(True)
    s.clock.advance(5)
    s.service._expire_outcomes(s.clock.time())
    assert s.waiter.outcome == o and late.outcome == o


def test_receiver_failure_and_callbacks(session):
    s = session(errors={"one", "all", "objectDone", "txDone", "outcome", "release"})
    for i, c in [(0, "site-a"), (1, "site-a"), (0, "site-b"), (1, "site-b")]:
        bad = i == 1 and c == "site-b"
        consumer = ByteConsumer(fail_complete=bad)
        if bad:
            with pytest.raises(RuntimeError, match="finalize"):
                s.download(i, c, consumer)
        else:
            s.download(i, c, consumer)
    o = s.await_settlement()
    assert not o.completed and o.quorum_met and o.done_status == "finished"
    assert not s.sources[0].released and s.sources[1].released
    assert len(s.done) == len(s.outcomes) == 1
    s.caller(False)


def eventually(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while not predicate() and time.monotonic() < deadline:
        REAL_SLEEP(0.005)
    assert predicate(), "expected source observation did not arrive"


def test_disjoint_receivers_and_idle_budget(session):
    s = session()
    s.download(0, "site-a")
    s.download(1, "site-b")
    eventually(
        lambda: s.tx.refs[0].receiver_statuses.get("site-a") == "success"
        and s.tx.refs[1].receiver_statuses.get("site-b") == "success"
    )
    s.clock.advance(3)
    s.clock.monitor(s.service)
    assert not s.waiter.done()  # strict greater-than threshold
    s.clock.advance(1)
    s.clock.monitor(s.service)
    o = s.await_settlement()
    assert o.done_status == "finished" and not o.completed and not o.quorum_met
    assert dict(o.refs[0].receiver_statuses) == {"site-a": "success", "site-b": "failed"}
    assert dict(o.refs[1].receiver_statuses) == {"site-b": "success", "site-a": "failed"}
    s.caller(False)


def test_active_receiver_and_stalled_sibling(session):
    s = session()
    s.download(0, "site-a")
    eventually(lambda: s.tx.refs[0].receiver_statuses.get("site-a") == "success")
    s.clock.advance(2)
    s.download(0, "site-b")
    eventually(lambda: s.tx.refs[0].receiver_statuses.get("site-b") == "success")
    s.clock.advance(2)
    b = ByteConsumer()
    b.complete_gate = threading.Event()
    f = s.launch(1, "site-b", b)
    assert b.complete_entered.wait(10)
    s.clock.monitor(s.service)
    assert s.tx.refs[1].receiver_statuses == {"site-a": "failed"}
    assert not s.waiter.done() and s.tx.last_active_time == s.clock.time()
    b.complete_gate.set()
    f.result(10)
    o = s.await_settlement()
    assert not o.completed and o.quorum_met
    s.caller(False)


def test_never_acquired_receiver(session):
    s = session()
    s.download(0, "site-a")
    s.download(1, "site-a")
    eventually(lambda: all(r.receiver_statuses.get("site-a") == "success" for r in s.tx.refs))
    late = s.service.get_transfer_waiter(s.tid)
    assert not late.done()
    s.clock.advance(4)
    s.clock.monitor(s.service)
    o = s.await_settlement()
    assert not o.completed and o.quorum_met and late.outcome == o
    assert all(r.receiver_statuses["site-b"] == "failed" for r in s.tx.refs)
    s.caller(False)


def test_pipeline_consume_failure(session):
    s = session()
    s.sources[0].terminal_gate = threading.Event()
    c = ByteConsumer(fail_consume=True)
    c.consume_gate = threading.Event()
    f = s.launch(0, "site-a", c)
    assert c.consume_entered.wait(10) and s.sources[0].terminal_entered.wait(10)
    c.consume_gate.set()
    f.result(10)
    eventually(lambda: all(r.receiver_statuses.get("site-a") == "failed" for r in s.tx.refs))
    assert s.tx._active_ops == 1  # admitted future survives Consumer failure/cancel
    s.sources[0].terminal_gate.set()
    eventually(lambda: s.tx._active_ops == 0)
    s.download(0, "site-b")
    s.download(1, "site-b")
    o = s.await_settlement()
    assert not o.completed and o.quorum_met
    assert len(c.failed) == 1
    s.caller(False)


def test_delete_with_late_confirmation(session):
    s = session()
    c = ByteConsumer()
    c.complete_gate = threading.Event()
    f = s.launch(0, "site-a", c)
    assert c.complete_entered.wait(10)
    s.service.delete_transaction(s.tid)
    o = s.await_settlement()
    assert o.status == "aborted" and not o.quorum_met
    c.complete_gate.set()
    f.result(10)
    eventually(lambda: not s.rec.s["confirmWire"])
    assert s.waiter.outcome == o and s.tx.refs[0].receiver_statuses == {}
    s.download(1, "site-b")  # supported late first acquisition -> missing ref
    s.caller(False)


def test_shutdown_pending_waiter(session):
    s = session()
    c = ByteConsumer()
    c.complete_gate = threading.Event()
    f = s.launch(0, "site-a", c)
    assert c.complete_entered.wait(10)
    s.service.shutdown()
    assert s.waiter.done() and s.waiter.outcome is None
    assert all(x.released for x in s.sources) and s.service.get_transfer_waiter(s.tid).outcome is None
    c.complete_gate.set()
    f.result(10)
    eventually(lambda: not s.rec.s["confirmWire"])
    s.caller(False)


def test_transaction_timeout(session):
    s = session(acquire=None, idle=None, timeout=5)
    s.clock.advance(5)
    s.clock.monitor(s.service)
    assert not s.waiter.done()
    s.clock.advance(1)
    s.clock.monitor(s.service)
    o = s.await_settlement()
    assert o.done_status == "timeout" and o.status == "failed"
    s.caller(False)


def test_producer_error(session):
    s = session()
    s.sources[0].fail_on_chunk = 1
    s.download(0, "site-a")
    s.download(1, "site-a")
    s.download(0, "site-b")
    s.download(1, "site-b")
    o = s.await_settlement()
    assert not o.completed and not o.quorum_met
    assert o.refs[0].receiver_statuses == {"site-a": "failed", "site-b": "failed"}
    s.caller(False)


def test_producer_exception(session):
    s = session(errors={"produce"})
    s.download(0, "site-a")
    s.download(0, "site-b")
    o = s.await_settlement()
    assert not o.completed and not o.quorum_met
    assert all(r.receiver_statuses == {"site-a": "failed", "site-b": "failed"} for r in s.tx.refs)
    s.caller(False)


def test_bounded_drain_and_late_cancel(session):
    s = session()
    s.sources[0].terminal_gate = threading.Event()
    c = ByteConsumer(fail_consume=True)
    c.consume_gate = threading.Event()
    f = s.launch(0, "site-a", c)
    assert c.consume_entered.wait(10) and s.sources[0].terminal_entered.wait(10)
    draining = threading.Event()
    s.rec.gates["drain_begin"] = lambda v, fs: draining.set()
    deletion = s.background.submit(s.service.delete_transaction, s.tid)
    assert draining.wait(10)
    s.clock.advance(2)
    with s.tx._ops_cond:
        s.tx._ops_cond.notify_all()
    deletion.result(10)
    o = s.waiter.wait(10)
    assert o is not None and o.status == "aborted" and s.tx._active_ops == 1
    assert s.tid in s.service._terminating_txs and all(x.released for x in s.sources)
    c.consume_gate.set()
    f.result(10)
    eventually(lambda: not s.rec.s["cancelWire"])
    s.sources[0].terminal_gate.set()
    eventually(lambda: s.tx._active_ops == 0)
    s.service._reap_termination_markers()
    assert s.tid not in s.service._terminating_txs and s.waiter.outcome == o
    s.caller(False)


def test_lost_confirmation(session, monkeypatch):
    s = session()
    real_send = s.cells[1]._fire_and_forget

    def transport_failure(*args, **kwargs):
        if "confirm" in kwargs["message"].payload:
            raise OSError("injected local confirmation send failure")
        return real_send(*args, **kwargs)

    monkeypatch.setattr(s.cells[1], "_fire_and_forget", transport_failure)
    s.download(0, "site-a")
    s.download(1, "site-a")
    s.download(0, "site-b")
    s.download(1, "site-b")
    eventually(lambda: all(r.receiver_statuses.get("site-b") == "success" for r in s.tx.refs))
    assert all(r.receiver_statuses.get("site-a") is None for r in s.tx.refs)
    s.clock.advance(4)
    s.clock.monitor(s.service)
    o = s.await_settlement()
    assert not o.completed and o.quorum_met
    s.caller(False)


def test_executor_stopped_fallback(session):
    s = session()
    s.pool.shutdown(wait=True)
    for i, c in [(0, "site-a"), (1, "site-a"), (0, "site-b"), (1, "site-b")]:
        s.download(i, c)
    o = s.await_settlement()
    assert o.completed and len(s.done) == 1
    assert s.rec.s["recordedBy"] == trace.INLINE
    s.caller(True)


def test_queue_then_submit_exception(session, monkeypatch):
    s = session()
    real_adjust = s.pool._adjust_thread_count

    def fail_adjust():
        raise RuntimeError("injected local worker-start failure after queue publication")

    monkeypatch.setattr(s.pool, "_adjust_thread_count", fail_adjust)
    for i, c in [(0, "site-a"), (1, "site-a"), (0, "site-b"), (1, "site-b")]:
        s.download(i, c)
    o = s.await_settlement()
    assert o.completed and len(s.done) == 1 and s.rec.s["queued"]
    monkeypatch.setattr(s.pool, "_adjust_thread_count", real_adjust)
    # Ordinary subsequent submission starts a real worker, which consumes the
    # original queued settlement item. No queue item is fabricated or reinserted.
    s.pool.submit(lambda: None).result(10)
    eventually(lambda: s.rec.s["spc"][trace.WORKER] == "done")
    assert len(s.done) == 2 and len(s.outcomes) == 2
    assert s.rec.s["receiptWrites"] == 1 and s.waiter.outcome == o
    s.caller(True)


def test_outcome_computation_exception(session, monkeypatch):
    s = session()

    def compute_failure(*args, **kwargs):
        raise RuntimeError("injected ordinary outcome computation exception")

    monkeypatch.setattr(ds, "compute_transfer_outcome", compute_failure)
    for i, c in [(0, "site-a"), (1, "site-a"), (0, "site-b"), (1, "site-b")]:
        s.download(i, c)
    o = s.await_settlement()
    assert o.reason == "computation_failed" and o.refs == () and not o.quorum_met
    assert all(x.released for x in s.sources) and s.outcomes == [o]
    s.caller(False)
