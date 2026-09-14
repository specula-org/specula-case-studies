#!/usr/bin/env python3
"""Reproduce MC-1: post-enqueue submit failure duplicates settlement effects.

The producer path is normal: create a DownloadService transaction, serve a
confirm-capable receiver to EOF, then send the receiver's legitimate
confirmation. The only injected precondition is the MC-modeled submit fault:
ThreadPoolExecutor has accepted the settlement work item, but Thread.start()
raises RuntimeError before a worker exists to run it.
"""

import threading
import time
import weakref
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import Mock

from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode
from nvflare.fuel.f3.cellnet.utils import new_cell_message
from nvflare.fuel.f3.streaming import download_service as download_service_module
from nvflare.fuel.f3.streaming.download_service import (
    DownloadService,
    DownloadStatus,
    Downloadable,
    ProduceRC,
    _PropKey,
)
from nvflare.fuel.f3.streaming.stream_utils import CheckedExecutor


class IsolatedDownloadService(DownloadService):
    _tx_table = {}
    _ref_table = {}
    _finished_refs = {}
    _tx_outcomes = {}
    _outcome_owners = {}
    _tx_waiters = {}
    _terminating_txs = {}
    _outcome_lock = threading.Lock()
    _logger = Mock()
    _tx_lock = threading.Lock()
    _tx_monitor = Mock()
    _initialized_cells = weakref.WeakKeyDictionary()
    _source_failure_lock = threading.Lock()
    _source_failures = {}
    _active_source_downloads = {}


class DummyCell:
    def register_request_cb(self, **_kwargs):
        return None


class CountingDownloadable(Downloadable):
    def __init__(self):
        super().__init__(obj="source-object")
        self.transaction_done_calls = []
        self.downloaded_to_one_calls = []
        self.downloaded_to_all_calls = 0
        self.release_calls = 0
        self.tx_id = None
        self.ref_id = None

    def set_transaction(self, tx_id: str, ref_id: str):
        self.tx_id = tx_id
        self.ref_id = ref_id

    def produce(self, state: dict, requester: str):
        if not state:
            return ProduceRC.OK, b"x", {"offset": 1}
        return ProduceRC.EOF, None, {}

    def downloaded_to_one(self, to_receiver: str, status: str):
        self.downloaded_to_one_calls.append((to_receiver, status))

    def downloaded_to_all(self):
        self.downloaded_to_all_calls += 1

    def transaction_done(self, transaction_id: str, status: str):
        self.transaction_done_calls.append((transaction_id, status))

    def release(self):
        self.release_calls += 1


def pull_request(ref_id, requester, state=None):
    payload = {_PropKey.REF_ID: ref_id, _PropKey.CONFIRM_CAPABLE: True}
    if state is not None:
        payload[_PropKey.STATE] = state
    return new_cell_message(headers={MessageHeaderKey.ORIGIN: requester}, payload=payload)


def confirm_request(ref_id, requester, status, nonce):
    return new_cell_message(
        headers={MessageHeaderKey.ORIGIN: requester},
        payload={
            _PropKey.REF_ID: ref_id,
            _PropKey.CONFIRM: status,
            _PropKey.CONFIRM_NONCE: nonce,
        },
    )


def pull_to_terminal(service, ref_id, requester):
    state = None
    for _ in range(10):
        reply = service._handle_download(pull_request(ref_id, requester, state))
        assert reply.get_header(MessageHeaderKey.RETURN_CODE) == ReturnCode.OK
        status = reply.payload.get(_PropKey.STATUS)
        if status in (ProduceRC.EOF, ProduceRC.ERROR):
            return reply
        state = reply.payload.get(_PropKey.STATE)
    raise AssertionError("producer never served terminal reply")


def reset_service_state():
    IsolatedDownloadService._tx_table = {}
    IsolatedDownloadService._ref_table = {}
    IsolatedDownloadService._finished_refs = {}
    IsolatedDownloadService._tx_outcomes = {}
    IsolatedDownloadService._outcome_owners = {}
    IsolatedDownloadService._tx_waiters = {}
    IsolatedDownloadService._terminating_txs = {}
    IsolatedDownloadService._outcome_lock = threading.Lock()
    IsolatedDownloadService._logger = Mock()
    IsolatedDownloadService._tx_lock = threading.Lock()
    IsolatedDownloadService._tx_monitor = Mock()
    IsolatedDownloadService._initialized_cells = weakref.WeakKeyDictionary()
    IsolatedDownloadService._source_failure_lock = threading.Lock()
    IsolatedDownloadService._source_failures = {}
    IsolatedDownloadService._active_source_downloads = {}


def run_transfer(label, *, inject_post_enqueue_submit_failure=False, delay_callback=False):
    reset_service_state()
    service = IsolatedDownloadService
    tx_done_cb_calls = []
    outcome_cb_calls = []

    def transaction_done_cb(tid, status, base_objs):
        if delay_callback:
            time.sleep(0.05)
        tx_done_cb_calls.append((tid, status, tuple(base_objs)))

    tx_id = service.new_transaction(
        cell=DummyCell(),
        timeout=10.0,
        num_receivers=1,
        transaction_done_cb=transaction_done_cb,
        outcome_cb=lambda outcome: outcome_cb_calls.append((outcome.tx_id, outcome.status)),
    )
    obj = CountingDownloadable()
    ref_id = service.add_object(tx_id, obj)
    waiter = service.get_transfer_waiter(tx_id)

    terminal = pull_to_terminal(service, ref_id, "receiver1")
    nonce = terminal.payload.get(_PropKey.CONFIRM_NONCE)
    assert terminal.payload.get(_PropKey.CONFIRM_EXPECTED) is True
    assert nonce, "terminal serve must carry the confirmation nonce"

    pool = CheckedExecutor(max_workers=1, thread_name_prefix=f"mc1_settle_{label}")
    original_pool = download_service_module.callback_thread_pool
    real_start = threading.Thread.start
    failed_once = False

    def fail_first_settlement_worker_start(thread):
        nonlocal failed_once
        if thread.name.startswith(f"mc1_settle_{label}") and not failed_once:
            failed_once = True
            raise RuntimeError("can't start new thread")
        return real_start(thread)

    download_service_module.callback_thread_pool = pool
    if inject_post_enqueue_submit_failure:
        threading.Thread.start = fail_first_settlement_worker_start
    try:
        reply = service._handle_download(confirm_request(ref_id, "receiver1", DownloadStatus.SUCCESS, nonce))
    finally:
        threading.Thread.start = real_start
        download_service_module.callback_thread_pool = original_pool

    assert reply.get_header(MessageHeaderKey.RETURN_CODE) == ReturnCode.OK
    if inject_post_enqueue_submit_failure:
        assert failed_once, "the post-enqueue submit RuntimeError was not injected"

    # In the injected case, the inline fallback already settled once. This
    # recovered submission starts a worker that drains the queued settlement item,
    # then the no-op. In the non-injected cases it is simply a bounded pool drain.
    pool.submit(lambda: None).result(timeout=5.0)
    pool.shutdown(wait=True)

    outcome = waiter.wait(timeout=5.0)
    assert outcome is not None and outcome.completed

    result = {
        "tx_id": tx_id,
        "ref_id": ref_id,
        "injected_fault": failed_once,
        "object_transaction_done_calls": obj.transaction_done_calls,
        "transaction_done_cb_calls": tx_done_cb_calls,
        "outcome_cb_calls": outcome_cb_calls,
        "release_calls": obj.release_calls,
        "waiter_done": waiter.done(),
        "outcome_completed": outcome.completed,
        "outcome_status": outcome.status,
        "recorded_outcomes": list(service._tx_outcomes.keys()),
    }
    print(f"{label}: {result!r}")
    return result


def main():
    level0 = run_transfer("level0_normal")
    level1 = run_transfer("level1_timing_only", delay_callback=True)
    level2 = run_transfer("level2_post_enqueue_fault", inject_post_enqueue_submit_failure=True)

    assert len(level0["object_transaction_done_calls"]) == 1, "Level 0 should not duplicate settlement"
    assert len(level1["object_transaction_done_calls"]) == 1, "Level 1 timing-only should not duplicate settlement"
    assert level2["injected_fault"], "Level 2 must inject the modeled post-enqueue submit failure"
    assert len(level2["object_transaction_done_calls"]) == 2, "expected duplicate object transaction_done effects"
    assert len(level2["transaction_done_cb_calls"]) == 2, "expected duplicate transaction_done_cb effects"
    assert len(level2["outcome_cb_calls"]) == 2, "expected duplicate outcome_cb effects"
    assert level2["release_calls"] == 2, "expected duplicate source release attempts"
    assert level2["recorded_outcomes"] == [level2["tx_id"]], "owner guard should still keep one stored receipt"
    print("BUG_REPRODUCED duplicate settlement side effects with one stored receipt")


if __name__ == "__main__":
    main()
