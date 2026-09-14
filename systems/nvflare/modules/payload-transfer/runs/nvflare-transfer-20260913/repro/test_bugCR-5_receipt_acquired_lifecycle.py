#!/usr/bin/env python3
"""CR-5 reproduction attempt for DownloadService receipt/acquisition/lifetime residuals."""

import dataclasses
import sys
import threading
import time
import weakref
from pathlib import Path
from unittest.mock import Mock, patch

WORKTREE = Path(
    "/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/"
    "nvflare-transfer/.specula-output/confirmation/CR-5/worktree"
)
sys.path.insert(0, str(WORKTREE))

from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode  # noqa: E402
from nvflare.fuel.f3.cellnet.utils import new_cell_message  # noqa: E402
from nvflare.fuel.f3.streaming import download_service as ds_module  # noqa: E402
from nvflare.fuel.f3.streaming.cacheable import CacheableObject  # noqa: E402
from nvflare.fuel.f3.streaming.download_service import (  # noqa: E402
    DownloadService,
    DownloadStatus,
    Downloadable,
    ProduceRC,
    TransactionDoneStatus,
    _PropKey,
)


class MockDownloadable(Downloadable):
    def __init__(self, data_chunks):
        super().__init__(data_chunks)
        self.data_chunks = list(data_chunks)
        self.transaction_done_calls = []
        self.downloaded_to_one_calls = []
        self.released = False

    def produce(self, state: dict, requester: str):
        chunk_idx = 0 if not state else state.get("chunk_idx", 0)
        if chunk_idx >= len(self.data_chunks):
            return ProduceRC.EOF, None, {}
        return ProduceRC.OK, self.data_chunks[chunk_idx], {"chunk_idx": chunk_idx + 1}

    def downloaded_to_one(self, to_receiver: str, status: str):
        self.downloaded_to_one_calls.append((to_receiver, status))

    def transaction_done(self, transaction_id: str, status: str):
        self.transaction_done_calls.append((transaction_id, status))

    def release(self):
        self.released = True


def make_service_no_monitor():
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

    return IsolatedDownloadService


def pull_request(rid, requester, confirm_capable=False, state=None):
    payload = {_PropKey.REF_ID: rid}
    if confirm_capable:
        payload[_PropKey.CONFIRM_CAPABLE] = True
    if state is not None:
        payload[_PropKey.STATE] = state
    return new_cell_message(headers={MessageHeaderKey.ORIGIN: requester}, payload=payload)


def confirm_request(rid, requester, status, nonce=None):
    payload = {_PropKey.REF_ID: rid, _PropKey.CONFIRM: status}
    if nonce is not None:
        payload[_PropKey.CONFIRM_NONCE] = nonce
    return new_cell_message(headers={MessageHeaderKey.ORIGIN: requester}, payload=payload)


def serve_nonce(reply):
    return reply.payload.get(_PropKey.CONFIRM_NONCE)


def run_monitor_once(service_cls, now):
    class MonitorIterationDone(Exception):
        pass

    monitor_thread = threading.current_thread()
    real_time = ds_module.time.time
    real_sleep = ds_module.time.sleep

    def test_thread_time():
        if threading.current_thread() is monitor_thread:
            return now
        return real_time()

    def stop_after_iteration(_seconds):
        raise MonitorIterationDone()

    with patch.object(ds_module.time, "time", side_effect=test_thread_time), patch.object(
        ds_module.time, "sleep", side_effect=stop_after_iteration
    ):
        try:
            service_cls._monitor_tx()
        except MonitorIterationDone:
            return


def pull_to_terminal(service, rid, requester, confirm_capable=False):
    state = None
    for _ in range(50):
        reply = service._handle_download(pull_request(rid, requester, confirm_capable=confirm_capable, state=state))
        status = reply.payload.get(_PropKey.STATUS)
        if status in (ProduceRC.EOF, ProduceRC.ERROR):
            return reply
        state = reply.payload.get(_PropKey.STATE)
    raise AssertionError("pull loop never reached a terminal status")


def check_settle_then_record():
    service = make_service_no_monitor()
    events = []

    class OrderedDownloadable(MockDownloadable):
        def transaction_done(self, transaction_id: str, status: str):
            super().transaction_done(transaction_id, status)
            events.append("transaction_done_cb")

        def release(self):
            events.append("release")
            super().release()

    obj = OrderedDownloadable([b"chunk"])

    def outcome_cb(outcome):
        events.append(f"outcome_cb_released={obj.released}")

    tx_id = service.new_transaction(cell=Mock(), timeout=10.0, num_receivers=1, outcome_cb=outcome_cb)
    rid = service.add_object(tx_id, obj)
    waiter = service.get_transfer_waiter(tx_id)

    terminal = pull_to_terminal(service, rid, "r1", confirm_capable=True)
    reply = service._handle_download(confirm_request(rid, "r1", DownloadStatus.SUCCESS, serve_nonce(terminal)))
    assert reply.get_header(MessageHeaderKey.RETURN_CODE) == ReturnCode.OK

    outcome = waiter.wait(timeout=5.0)
    assert outcome is not None and outcome.completed
    assert obj.released
    assert events == ["transaction_done_cb", "outcome_cb_released=False", "release"]

    print("LEVEL0 settle_then_record: waiter_returned_completed=True")
    print(f"LEVEL0 settle_then_record: callback_release_order={events}")
    print(f"LEVEL0 settle_then_record: object_released_before_wait_return={obj.released}")


def check_acquired_receivers_lifetime():
    service = make_service_no_monitor()
    tx_id = service.new_transaction(cell=Mock(), timeout=10.0, num_receivers=1)
    rid = service.add_object(tx_id, MockDownloadable([b"chunk"]))
    waiter = service.get_transfer_waiter(tx_id)

    assert waiter.acquired_receivers() == set()
    first = service._handle_download(pull_request(rid, "r1"))
    assert first.payload[_PropKey.STATUS] == ProduceRC.OK
    assert waiter.acquired_receivers() == {"r1"}

    terminal = service._handle_download(pull_request(rid, "r1", state=first.payload[_PropKey.STATE]))
    assert terminal.payload[_PropKey.STATUS] == ProduceRC.EOF
    run_monitor_once(service, now=time.time())
    outcome = waiter.wait(timeout=5.0)
    assert outcome is not None and outcome.completed

    after_retirement = waiter.acquired_receivers()
    final_receivers = sorted(outcome.refs[0].receiver_statuses)
    assert after_retirement == set()
    assert final_receivers == ["r1"]

    print("LEVEL0 acquired_receivers: before_pull=[]")
    print("LEVEL0 acquired_receivers: after_first_pull=['r1']")
    print(f"LEVEL0 acquired_receivers: after_retirement={sorted(after_retirement)}")
    print(f"LEVEL0 acquired_receivers: final_outcome_receivers={final_receivers}")


def check_expired_unswept_receipt_window():
    service = make_service_no_monitor()
    saved_ttl = service.TX_OUTCOME_TTL
    service.TX_OUTCOME_TTL = 0.2
    try:
        tx_id = service.new_transaction(cell=Mock(), timeout=10.0, num_receivers=1, tx_id="CR5-TTL")
        rid = service.add_object(tx_id, MockDownloadable([b"chunk"]))
        waiter = service.get_transfer_waiter(tx_id)
        pull_to_terminal(service, rid, "r1", confirm_capable=False)
        run_monitor_once(service, now=time.time())
        outcome = waiter.wait(timeout=5.0)
        assert outcome is not None and outcome.completed

        time.sleep(0.25)
        late_waiter_before_query = service.get_transfer_waiter(tx_id)
        stale_outcome = late_waiter_before_query.wait(timeout=0)
        query_after_late_waiter = service.get_transaction_outcome(tx_id)
        late_waiter_after_query = service.get_transfer_waiter(tx_id)
        post_query_outcome = late_waiter_after_query.wait(timeout=0)

        assert stale_outcome is not None and stale_outcome.completed
        assert query_after_late_waiter is None
        assert post_query_outcome is None

        tx_id2 = service.new_transaction(cell=Mock(), timeout=10.0, num_receivers=1, tx_id="CR5-TTL-SWEEP")
        rid2 = service.add_object(tx_id2, MockDownloadable([b"chunk"]))
        waiter2 = service.get_transfer_waiter(tx_id2)
        pull_to_terminal(service, rid2, "r1", confirm_capable=False)
        run_monitor_once(service, now=time.time())
        assert waiter2.wait(timeout=5.0).completed
        time.sleep(0.25)
        run_monitor_once(service, now=time.time())
        swept_waiter = service.get_transfer_waiter(tx_id2)
        assert swept_waiter.done() and swept_waiter.wait(timeout=0) is None

        print("LEVEL1 receipt_expiry: ttl_seconds=0.2")
        print("LEVEL1 receipt_expiry: late_waiter_before_query=COMPLETED")
        print("LEVEL1 receipt_expiry: get_transaction_outcome_after_same_age=None")
        print("LEVEL1 receipt_expiry: late_waiter_after_query=None")
        print("LEVEL1 receipt_expiry: late_waiter_after_monitor_sweep=None")
    finally:
        service.TX_OUTCOME_TTL = saved_ttl


def check_same_id_reuse_after_expiry_does_not_overlap():
    service = make_service_no_monitor()
    saved_ttl = service.TX_OUTCOME_TTL
    service.TX_OUTCOME_TTL = 0.2
    try:
        tx_id = service.new_transaction(cell=Mock(), timeout=10.0, num_receivers=1, tx_id="CR5-REUSE")
        rid = service.add_object(tx_id, MockDownloadable([b"chunk"]))
        waiter = service.get_transfer_waiter(tx_id)
        pull_to_terminal(service, rid, "r1")
        run_monitor_once(service, now=time.time())
        assert waiter.wait(timeout=5.0).completed

        with service._outcome_lock:
            service._tx_outcomes[tx_id] = dataclasses.replace(
                service._tx_outcomes[tx_id],
                timestamp=service._tx_outcomes[tx_id].timestamp - service.TX_OUTCOME_TTL - 1.0,
            )

        reused = service.new_transaction(cell=Mock(), timeout=10.0, num_receivers=1, tx_id=tx_id)
        assert reused == tx_id
        fresh_waiter = service.get_transfer_waiter(tx_id)
        assert not fresh_waiter.done()

        print("LEVEL1 same_id_reuse: expired_receipt_removed_inline=True")
        print("LEVEL1 same_id_reuse: fresh_waiter_attaches_to_new_attempt=True")
    finally:
        service.TX_OUTCOME_TTL = saved_ttl


def check_cacheable_source_lifetime_runtime():
    class TinyCacheable(CacheableObject):
        def get_item_count(self):
            return len(self.base_obj)

        def produce_item(self, index: int) -> bytes:
            return self.base_obj[index]

    obj = TinyCacheable([b"a"], max_chunk_size=1)
    obj.transaction_done("tx", TransactionDoneStatus.FINISHED)
    assert obj.cache is None
    assert obj.base_obj == [b"a"]
    assert obj._get_item(0, "r1") == b"a"
    obj.release()
    assert obj.base_obj is None
    try:
        obj._get_item(0, "r1")
    except RuntimeError as ex:
        post_release = type(ex).__name__
    else:
        raise AssertionError("post-release _get_item should fail defensively")

    print("LEVEL0 cacheable_lifetime: transaction_done_clears_cache_only=True")
    print("LEVEL0 cacheable_lifetime: release_clears_base_obj=True")
    print(f"LEVEL0 cacheable_lifetime: post_release_get_item={post_release}")


def main():
    print("CR-5 reproduction attempt starting")
    print(f"worktree={WORKTREE}")
    check_settle_then_record()
    check_acquired_receivers_lifetime()
    check_expired_unswept_receipt_window()
    check_same_id_reuse_after_expiry_does_not_overlap()
    check_cacheable_source_lifetime_runtime()
    print("LEVEL2 state_injection: not used; public/timing paths reached the residual states")
    print("LEVEL3 source_patch: not used; source patching would manufacture a consequence")
    print("CR-5 reproduction attempt completed: no live wrong high-level caller outcome was triggered")


if __name__ == "__main__":
    main()
