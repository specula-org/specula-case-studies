#!/usr/bin/env python3
"""CR-2 repro: stream Cell.fire_and_forget underdeclares multi-target payload receivers."""

import copy
import logging

from nvflare.fuel.f3.cellnet.cell import Cell
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode
from nvflare.fuel.f3.cellnet.utils import new_cell_message
from nvflare.fuel.f3.message import Message
from nvflare.fuel.f3.streaming.download_service import (
    Consumer,
    DownloadService,
    Downloadable,
    ProduceRC,
    download_object,
)
from nvflare.fuel.f3.streaming.stream_const import StreamHeaderKey
from nvflare.fuel.f3.streaming.transfer_outcome import DownloadStatus
from nvflare.fuel.utils import fobs
from nvflare.fuel.utils.fobs.decomposers.via_downloader import ViaDownloaderDecomposer


class Payload:
    def __init__(self, value):
        self.value = value


class BatchDownloadable(Downloadable):
    def __init__(self, items):
        super().__init__(items)
        self.items = dict(items)
        self.tx_id = None
        self.ref_id = None
        self.released = False
        self.downloaded_to_one_calls = []
        self.downloaded_to_all_calls = 0
        self.transaction_done_calls = []

    def set_transaction(self, tx_id, ref_id):
        self.tx_id = tx_id
        self.ref_id = ref_id

    def produce(self, state, requester):
        if state and state.get("done"):
            return ProduceRC.EOF, None, {}
        return ProduceRC.OK, self.items, {"done": True}

    def downloaded_to_one(self, to_receiver, status):
        self.downloaded_to_one_calls.append((to_receiver, status))

    def downloaded_to_all(self):
        self.downloaded_to_all_calls += 1

    def transaction_done(self, transaction_id, status):
        self.transaction_done_calls.append((transaction_id, status))

    def release(self):
        self.released = True


class CollectingConsumer(Consumer):
    def __init__(self):
        super().__init__()
        self.items = {}
        self.completed = False
        self.failed = None

    def consume(self, ref_id, state, data):
        self.items.update(data)
        return state

    def download_completed(self, ref_id):
        self.completed = True

    def download_failed(self, ref_id, reason):
        self.failed = reason


class PayloadDecomposer(ViaDownloaderDecomposer):
    def __init__(self):
        super().__init__(max_chunk_size=1, config_var_prefix="cr2_")
        self.downloadable = None
        self.downloads = {}

    def supported_type(self):
        return Payload

    def get_download_dot(self):
        return 201

    def native_decompose(self, target, manager=None):
        return target.value.encode("utf-8")

    def native_recompose(self, data, manager=None):
        return Payload(data.decode("utf-8"))

    def to_downloadable(self, items, max_chunk_size, fobs_ctx):
        self.downloadable = BatchDownloadable(items)
        return self.downloadable

    def download(
        self,
        from_fqcn,
        ref_id,
        per_request_timeout,
        cell,
        secure=False,
        optional=False,
        abort_signal=None,
        progress_cb=None,
    ):
        consumer = CollectingConsumer()
        self.downloads[cell.get_fqcn()] = consumer
        download_object(
            from_fqcn=from_fqcn,
            ref_id=ref_id,
            per_request_timeout=per_request_timeout,
            cell=cell,
            consumer=consumer,
            secure=secure,
            optional=optional,
            abort_signal=abort_signal,
            progress_cb=progress_cb,
            max_retries=0,
        )
        if consumer.failed:
            return consumer.failed, {}
        return None, consumer.items


def make_source_cell():
    cell = Cell.__new__(Cell)
    cell.logger = logging.getLogger("cr2.source")
    cell.requests_dict = {}
    cell.decode_pass_through_channels = set()
    cell.decode_pass_through_topics = set()
    cell.sent_messages = []

    def get_fqcn():
        return "source"

    def get_fobs_context(props=None):
        ctx = {fobs.FOBSContextKey.CELL: cell}
        if props:
            ctx.update(props)
        return ctx

    def register_request_cb(**kwargs):
        return None

    def send_blob(**kwargs):
        msg = kwargs["message"]
        payload = list(msg.payload) if isinstance(msg.payload, list) else copy.deepcopy(msg.payload)
        snapshot = Message(headers=dict(msg.headers), payload=payload)
        cell.sent_messages.append((kwargs["target"], snapshot))
        return object()

    cell.get_fqcn = get_fqcn
    cell.get_fobs_context = get_fobs_context
    cell.register_request_cb = register_request_cb
    cell.send_blob = send_blob
    return cell


class ReceiverCell:
    def __init__(self, fqcn):
        self._fqcn = fqcn
        self.registered_callbacks = []

    def get_fqcn(self):
        return self._fqcn

    def get_fobs_context(self, props=None):
        ctx = {fobs.FOBSContextKey.CELL: self}
        if props:
            ctx.update(props)
        return ctx

    def register_request_cb(self, **kwargs):
        self.registered_callbacks.append(kwargs)

    def send_request(self, channel, target, topic, request, timeout=None, secure=False, optional=False, abort_signal=None):
        request.set_header(MessageHeaderKey.ORIGIN, self._fqcn)
        return DownloadService._handle_download(request)

    def fire_and_forget(self, channel, topic, targets, message, secure=False, optional=False):
        if isinstance(targets, str):
            targets = [targets]
        result = {}
        for target in targets:
            message.set_header(MessageHeaderKey.ORIGIN, self._fqcn)
            reply = DownloadService._handle_download(message)
            rc = reply.get_header(MessageHeaderKey.RETURN_CODE)
            result[target] = "" if rc == ReturnCode.OK else rc
        return result


def clone_message(msg):
    payload = list(msg.payload) if isinstance(msg.payload, list) else copy.deepcopy(msg.payload)
    return Message(headers=dict(msg.headers), payload=payload)


def decode_at_receiver(encoded_msg, receiver):
    msg = clone_message(encoded_msg)
    decode_ctx = receiver.get_fobs_context()
    from nvflare.fuel.f3.cellnet.utils import decode_payload

    decode_payload(msg, StreamHeaderKey.PAYLOAD_ENCODING, fobs_ctx=decode_ctx)
    return msg.payload


def main():
    # Start from a clean process-global DownloadService table.
    DownloadService.shutdown()

    decomposer = PayloadDecomposer()
    fobs.register(decomposer)

    source = make_source_cell()
    receiver_a = ReceiverCell("receiver-a")
    receiver_b = ReceiverCell("receiver-b")

    message = new_cell_message({}, {"payload": Payload("model-v1")})
    result = source.fire_and_forget(
        channel="training-stream",
        topic="fanout-result",
        targets=["receiver-a", "receiver-b"],
        message=message,
        optional=True,
    )

    downloadable = decomposer.downloadable
    assert downloadable is not None, "FOBS did not create a DownloadService-backed payload"
    tx_id = downloadable.tx_id
    ref_id = downloadable.ref_id
    tx = DownloadService._tx_table[tx_id]
    waiter = DownloadService.get_transfer_waiter(tx_id)

    print(f"send_result={result}")
    print(f"sent_targets={[target for target, _ in source.sent_messages]}")
    print(f"tx_id={tx_id} ref_id={ref_id}")
    print(f"tx_num_receivers={tx.num_receivers} tx_receiver_ids={tx.receiver_ids}")

    encoded_by_target = {target: sent for target, sent in source.sent_messages}
    decoded_a = decode_at_receiver(encoded_by_target["receiver-a"], receiver_a)
    assert decoded_a["payload"].value == "model-v1"

    outcome = waiter.wait(timeout=5.0)
    assert outcome is not None, "producer waiter did not resolve"
    first_ref_statuses = dict(outcome.refs[0].receiver_statuses)

    print(
        "after_receiver_a "
        f"outcome_completed={outcome.completed} "
        f"outcome_reason={outcome.reason} "
        f"outcome_num_receivers={outcome.num_receivers} "
        f"outcome_receiver_ids={outcome.receiver_ids} "
        f"outcome_ref_statuses={first_ref_statuses}"
    )
    print(
        "source_lifetime "
        f"released={downloadable.released} "
        f"downloaded_to_all_calls={downloadable.downloaded_to_all_calls} "
        f"transaction_done_calls={downloadable.transaction_done_calls}"
    )
    print(f"live_ref_after_receiver_a={DownloadService.get_transaction_id(ref_id)}")
    print(f"finished_ref_statuses={dict(DownloadService._finished_refs[ref_id].receiver_statuses)}")

    assert outcome.completed is True
    assert outcome.num_receivers == 1
    assert outcome.receiver_ids is None
    assert first_ref_statuses == {"receiver-a": DownloadStatus.SUCCESS}
    assert downloadable.released is True
    assert DownloadService.get_transaction_id(ref_id) is None

    receiver_b_error = None
    try:
        decode_at_receiver(encoded_by_target["receiver-b"], receiver_b)
    except RuntimeError as ex:
        receiver_b_error = str(ex)

    receiver_b_consumer = decomposer.downloads.get("receiver-b")
    receiver_b_failed = receiver_b_consumer.failed if receiver_b_consumer else None
    print(f"receiver_b_failed={receiver_b_failed}")
    print(f"receiver_b_decode_error={receiver_b_error}")

    assert receiver_b_error is not None
    assert "failed to download from source" in receiver_b_error
    assert receiver_b_failed is not None
    assert "invalid_request" in receiver_b_failed

    print("CR-2 reproduced: one receiver completed a two-target fire_and_forget payload and retired the source")
    DownloadService.shutdown()


if __name__ == "__main__":
    main()
