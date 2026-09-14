#!/usr/bin/env python3
"""Reproduce MC-2: pipelined EOF publishes completed progress after cancel finalizes FAILED.

Run from the NVFlare checkout:
    python ../repro/test_bugMC-2_pipelined_eof_cancel_progress.py
"""

from __future__ import annotations

import sys
import threading
import time
import weakref
from pathlib import Path
from typing import Any, Optional


WORKTREE = (
    Path(__file__).resolve().parents[1]
    / "confirmation"
    / "MC-2"
    / "worktree"
)
sys.path.insert(0, str(WORKTREE))

from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.fuel.f3.streaming import download_service as ds_module  # noqa: E402
from nvflare.fuel.f3.streaming.download_service import (  # noqa: E402
    OBJ_DOWNLOADER_CHANNEL,
    OBJ_DOWNLOADER_TOPIC,
    Consumer,
    Downloadable,
    DownloadService,
    DownloadStatus,
    ProduceRC,
    _PropKey,
    download_object,
)
from nvflare.fuel.f3.streaming.transfer_progress import TransferProgressState  # noqa: E402


SOURCE = "producer"
RECEIVER = "receiver1"


def _wait_until(predicate, timeout=3.0, interval=0.005, label="condition"):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(interval)
    raise AssertionError(f"timed out waiting for {label}")


def _reset_download_service():
    with DownloadService._tx_lock:
        DownloadService._tx_table.clear()
        DownloadService._ref_table.clear()
        DownloadService._finished_refs.clear()
        DownloadService._terminating_txs.clear()
    with DownloadService._outcome_lock:
        DownloadService._tx_outcomes.clear()
        DownloadService._outcome_owners.clear()
        DownloadService._tx_waiters.clear()
    with DownloadService._source_failure_lock:
        DownloadService._source_failures.clear()
        DownloadService._active_source_downloads.clear()
    DownloadService._initialized_cells = weakref.WeakKeyDictionary()
    DownloadService._tx_monitor = object()
    ds_module._receiver_confirm_cached = True


class LoopbackCell:
    """A local Cell stand-in that routes normal download messages to DownloadService."""

    def __init__(self):
        self.requests = []
        self.controls = []
        self.registered = []

    def register_request_cb(self, channel, topic, cb):
        self.registered.append((channel, topic, cb))

    def send_request(
        self,
        channel,
        target,
        topic,
        request,
        timeout,
        secure=False,
        optional=False,
        abort_signal=None,
        **_kwargs,
    ):
        assert channel == OBJ_DOWNLOADER_CHANNEL
        assert topic == OBJ_DOWNLOADER_TOPIC
        assert target == SOURCE
        request.set_header(MessageHeaderKey.ORIGIN, RECEIVER)
        self.requests.append(dict(request.payload))
        return DownloadService._handle_download(request)

    def fire_and_forget(self, channel, topic, targets, message, secure=False, optional=False):
        assert channel == OBJ_DOWNLOADER_CHANNEL
        assert topic == OBJ_DOWNLOADER_TOPIC
        assert targets == SOURCE
        message.set_header(MessageHeaderKey.ORIGIN, RECEIVER)
        self.controls.append(dict(message.payload))
        DownloadService._handle_download(message)


class RaceDownloadable(Downloadable):
    def __init__(self, gated: bool):
        super().__init__(obj=b"source-object")
        self.gated = gated
        self.eof_entered = threading.Event()
        self.allow_eof = threading.Event()
        self.cancel_callback_entered = threading.Event()
        self.allow_cancel_callback = threading.Event()
        self.downloaded_to_one_calls = []
        self.transaction_done_calls = []
        self.released = False

    def set_transaction(self, tx_id: str, ref_id: str):
        self.tx_id = tx_id
        self.ref_id = ref_id

    def produce(self, state: Optional[dict], requester: str):
        if not state:
            return ProduceRC.OK, b"chunk", {"chunk_idx": 1}
        self.eof_entered.set()
        if self.gated:
            assert self.allow_eof.wait(3.0), "test did not release the pipelined EOF"
        return ProduceRC.EOF, None, {}

    def downloaded_to_one(self, to_receiver: str, status: str):
        self.downloaded_to_one_calls.append((to_receiver, status))
        if self.gated and status == DownloadStatus.FAILED:
            self.cancel_callback_entered.set()
            assert self.allow_cancel_callback.wait(3.0), "test did not release cancel callback"

    def downloaded_to_all(self):
        pass

    def transaction_done(self, transaction_id: str, status: str):
        self.transaction_done_calls.append((transaction_id, status))

    def release(self):
        self.released = True


class FailingPipelinedConsumer(Consumer):
    supports_pipelining = True

    def __init__(self, obj: RaceDownloadable, wait_for_eof: bool):
        super().__init__()
        self.obj = obj
        self.wait_for_eof = wait_for_eof
        self.consumed = []
        self.completed = False
        self.failed_reason = None

    def consume(self, ref_id: str, state: dict, data: Any) -> dict:
        self.consumed.append((state, data))
        if self.wait_for_eof:
            assert self.obj.eof_entered.wait(3.0), "pipelined EOF request did not start"
        raise OSError("ENOSPC while storing streamed chunk")

    def download_completed(self, ref_id: str):
        self.completed = True

    def download_failed(self, ref_id: str, reason: str):
        self.failed_reason = reason


def run_attempt(gated: bool):
    _reset_download_service()
    cell = LoopbackCell()
    source_progress = []
    obj = RaceDownloadable(gated=gated)
    tx_id = DownloadService.new_transaction(
        cell=cell,
        timeout=10.0,
        num_receivers=1,
        receiver_ids=(RECEIVER,),
        progress_cb=lambda **event: source_progress.append(dict(event)),
        progress_interval=0.0,
    )
    ref_id = DownloadService.add_object(tx_id, obj, ref_id="ref1")
    waiter = DownloadService.get_transfer_waiter(tx_id)
    consumer = FailingPipelinedConsumer(obj, wait_for_eof=gated)
    receiver_progress = []
    errors = []

    def download_thread_main():
        try:
            download_object(
                from_fqcn=SOURCE,
                ref_id=ref_id,
                per_request_timeout=5.0,
                cell=cell,
                consumer=consumer,
                progress_cb=lambda **event: receiver_progress.append(dict(event)),
                progress_interval=0.0,
            )
        except BaseException as e:  # keep the assertion failure visible in main
            errors.append(repr(e))

    thread = threading.Thread(target=download_thread_main, name="receiver-download")
    thread.start()

    if gated:
        assert obj.eof_entered.wait(3.0), "pipelined EOF request did not enter produce()"
        assert obj.cancel_callback_entered.wait(3.0), "cancel did not reach downloaded_to_one()"
        obj.allow_eof.set()
        _wait_until(
            lambda: any(event["state"] == TransferProgressState.COMPLETED for event in source_progress),
            label="completed source progress",
        )
        obj.allow_cancel_callback.set()

    thread.join(timeout=5.0)
    if thread.is_alive():
        obj.allow_eof.set()
        obj.allow_cancel_callback.set()
        raise AssertionError("download thread did not finish")
    if errors:
        raise AssertionError(f"download thread raised: {errors}")

    outcome = waiter.wait(timeout=5.0)
    assert outcome is not None, "transfer waiter did not resolve"
    statuses = dict(outcome.refs[0].receiver_statuses) if outcome.refs else {}
    return {
        "source_states": [event["state"] for event in source_progress],
        "receiver_states": [event["state"] for event in receiver_progress],
        "outcome_status": outcome.status,
        "outcome_reason": outcome.reason,
        "receiver_statuses": statuses,
        "consumer_failed_reason": consumer.failed_reason,
        "consumer_completed": consumer.completed,
        "control_messages": cell.controls,
        "requests": cell.requests,
        "downloaded_to_one_calls": obj.downloaded_to_one_calls,
        "released": obj.released,
    }


def main():
    print("Level 0 attempt: public download/cancel path, no timing gates")
    level0 = run_attempt(gated=False)
    print(f"  source_states={level0['source_states']}")
    print(f"  outcome_status={level0['outcome_status']} receiver_statuses={level0['receiver_statuses']}")

    print("Level 1 attempt: same path with callback/event timing gates")
    level1 = run_attempt(gated=True)
    print(f"  requests={level1['requests']}")
    print(f"  control_messages={level1['control_messages']}")
    print(f"  source_states={level1['source_states']}")
    print(f"  receiver_states={level1['receiver_states']}")
    print(f"  downloaded_to_one_calls={level1['downloaded_to_one_calls']}")
    print(
        "  outcome="
        f"{level1['outcome_status']} reason={level1['outcome_reason']} "
        f"receiver_statuses={level1['receiver_statuses']}"
    )
    print(f"  consumer_failed_reason={level1['consumer_failed_reason']!r}")
    print(f"  source_released={level1['released']}")

    assert any(msg.get(_PropKey.CANCEL) is True for msg in level1["control_messages"])
    assert level1["receiver_statuses"] == {RECEIVER: DownloadStatus.FAILED}
    assert level1["outcome_status"] == TransferProgressState.FAILED
    assert level1["source_states"][-1] == TransferProgressState.COMPLETED
    assert TransferProgressState.FAILED not in level1["source_states"]
    assert level1["consumer_failed_reason"] and "ENOSPC" in level1["consumer_failed_reason"]

    print("BUG TRIGGERED: source progress ended as completed while receiver truth/outcome ended failed")


if __name__ == "__main__":
    main()
