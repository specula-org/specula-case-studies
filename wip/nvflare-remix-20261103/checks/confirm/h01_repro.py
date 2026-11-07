"""H01 (Phase 1 rank 4): an Attach trainer's send() reports success for a result
the CJ rejected, after both RESULT_REJECTED replies were lost.
Pinned source c411a201, read-only via sys.path.

Trainer side: CellClientAPI.send (nvflare/client/cell/api.py:453-588) calls
AttachTrainerSession.publish_result (attach_session.py:361-439). Each of the
_RESULT_SEND_ATTEMPTS=2 attempts sends RESULT_READY; a missing or non-OK reply
is "uncertain" and is resolved through RESULT_STATUS. After both attempts,
_resolve_ambiguous_result (441-467) asks RESULT_STATUS again and, when the CJ
answers UNKNOWN, treats an attempt whose transfer waiters all ended COMPLETED as
accepted (459). send() then waits for those transfers (543), marks the task
complete and returns normally.

CJ side: in attach mode the CJ is the terminal receiver and decodes RESULT_READY
itself (no pass-through route, attach_backend.py:203), so the lazy result is
downloaded - and its transfer completes, receiver-confirmed - before
CellBackendBase._handle_result_ready (cell_backend.py:195-268) runs. If the task
has closed by then (AttachBackend._run_task clears _current_task in its finally
on abort or result timeout, attach_backend.py:636-639), the handler answers
RESULT_REJECTED "no current task matching task_id" (236-242) without recording
result authority, so _handle_result_status answers UNKNOWN (281-282).

Real code: CellClientAPI.send, _wait_for_result_transfers, _notify_result_source_
settled; AttachTrainerSession.publish_result, _accepted_result_attempt,
_accepted_result_attempt_from_status, _resolve_ambiguous_result,
_keep_canonical_attempt, mark_result_publishing, mark_task_complete;
AttachBackend/CellBackendBase._handle_result_ready, _handle_result_status,
_handle_result_source_settled, _validate_session_msg, _protocol_reply; the real
TransferWaiter and TransferOutcome objects. Stubs: the cell transport (requests go
straight to the CJ handlers; a "lost" reply comes back as a cell TIMEOUT, as
send_request returns when no reply arrives), the FOBS encode/decode of the lazy
result (one transaction per attempt; the CJ's decode resolves its waiter with a
COMPLETED, receiver-confirmed outcome), and the task's closing (the same two
lines as _run_task's finally).

Scenarios:
  C1 task open, replies delivered        -> RESULT_ACCEPTED, the CJ holds the result
  C2 task closed, RESULT_REJECTED arrives -> send() raises "rejected"
  C3 task closed, both rejections lost, result small (no lazy transfer) -> send() raises
  H01 task closes after the CJ's download completed; both RESULT_REJECTED replies
      lost; RESULT_STATUS answers UNKNOWN -> send() returns normally
"""
import sys, threading, time, types, uuid
from collections import OrderedDict
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

import numpy as np  # noqa: E402

from nvflare.apis.signal import Signal  # noqa: E402
from nvflare.app_common.abstract.fl_model import FLModel  # noqa: E402
from nvflare.app_common.executors.client_api.attach_backend import AttachBackend, _AttachedTrainerSession  # noqa: E402
from nvflare.app_common.executors.client_api.cell_backend import CellTask  # noqa: E402
from nvflare.client.cell.api import CellClientAPI  # noqa: E402
from nvflare.client.cell.attach_session import AttachTrainerSession, TrainerSessionError  # noqa: E402
from nvflare.client.cell.defs import MsgKey, ResultState, Topic  # noqa: E402
from nvflare.client.config import ConfigKey, ExchangeFormat, TransferType  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import ReturnCode as CellReturnCode  # noqa: E402
from nvflare.fuel.f3.cellnet.utils import make_reply as make_cell_reply  # noqa: E402
from nvflare.fuel.f3.streaming import download_service as ds  # noqa: E402
from nvflare.fuel.f3.streaming.transfer_outcome import (  # noqa: E402
    TransactionDoneStatus,
    TransferOutcome,
    TransferOutcomeReason,
)
from nvflare.fuel.f3.streaming.transfer_progress import TransferProgressState  # noqa: E402
from nvflare.fuel.utils.fobs.decomposers.via_downloader import RESULT_UPLOAD_TX_CREATED_CB_CTX_KEY  # noqa: E402

CJ, TRAINER, TASK = "site-1.job1", "site-1.attach-a1", "task-1"
WAITERS = {}
ds.DownloadService.get_transfer_waiter = classmethod(lambda cls, tx_id: WAITERS[tx_id])
ds.DownloadService.delete_transaction = classmethod(lambda cls, tx_id: None)


def make_cj():
    be = AttachBackend.__new__(AttachBackend)
    be.logger = MagicMock()
    be._closed, be._task_lock, be._session_lock = False, threading.Lock(), threading.Lock()
    be._result_authority = OrderedDict()
    be._session = _AttachedTrainerSession(TRAINER)
    be._session.ready.set()
    be._current_task = CellTask(TASK)             # _run_task admitted the task
    return be


def close_task(be):
    """AttachBackend._run_task finally (attach_backend.py:637-639): abort or result timeout."""
    task = be._current_task
    with be._task_lock:
        if be._current_task is task:
            be._current_task = None


class Transport:
    """Trainer-side cell: requests go straight to the CJ's real handlers."""

    def __init__(self, be, lose_result_replies=False, lazy=True, close_after_download=False):
        self.be, self.lose, self.lazy, self.close_after_download = be, lose_result_replies, lazy, close_after_download
        self.log = []

    def send_request(self, channel, topic, target, request, timeout=None, fobs_ctx_props=None, **kw):
        request.set_header(MessageHeaderKey.ORIGIN, TRAINER)
        if topic == Topic.RESULT_READY:
            if self.lazy:
                # trainer encode: ViaDownloader creates this attempt's transaction
                tx_id = uuid.uuid4().hex
                WAITERS[tx_id] = ds.TransferWaiter(tx_id)
                fobs_ctx_props[RESULT_UPLOAD_TX_CREATED_CB_CTX_KEY](types.SimpleNamespace(tx_id=tx_id))
                # CJ decode (terminal receiver): it downloads the params; the transfer completes
                WAITERS[tx_id]._resolve(TransferOutcome(
                    tx_id=tx_id, status=TransferProgressState.COMPLETED,
                    reason=TransferOutcomeReason.ALL_RECEIVERS_SUCCEEDED, done_status=TransactionDoneStatus.FINISHED,
                    num_receivers=1, refs=(), timestamp=time.time(), receiver_ids=(CJ,)))
            if self.close_after_download:
                close_task(self.be)
            reply = self.be._handle_result_ready(request)
            lost = self.lose
        elif topic == Topic.RESULT_STATUS:
            reply, lost = self.be._handle_result_status(request), False
        elif topic == Topic.RESULT_SOURCE_SETTLED:
            reply, lost = self.be._handle_result_source_settled(request), False
        else:
            raise AssertionError(topic)
        body = reply.payload if isinstance(reply.payload, dict) else {}
        self.log.append((topic, body.get(MsgKey.REPLY_TOPIC), body.get(MsgKey.RESULT_STATE) or body.get(MsgKey.REASON),
                         "LOST" if lost else "delivered"))
        return make_cell_reply(CellReturnCode.TIMEOUT) if lost else reply


def make_trainer(be, transport):
    api = CellClientAPI.__new__(CellClientAPI)
    api.logger = MagicMock()
    api._is_control_rank, api._closed, api._stopped, api._abort, api._abort_reason = True, False, False, False, ""
    api._receive_called, api._current_task = True, {MsgKey.TASK_ID: TASK}
    api._task_exchange = {ConfigKey.TRANSFER_TYPE: TransferType.FULL, ConfigKey.EXCHANGE_FORMAT: ExchangeFormat.NUMPY,
                          ConfigKey.SERVER_EXPECTED_FORMAT: ExchangeFormat.NUMPY, ConfigKey.LAUNCH_ONCE: True}
    api._launch_once, api._memory_gc_rounds, api._cuda_empty_cache = True, 0, False
    api._params_conversion_state, api._fl_model, api._result_receiver_ids = {}, None, None
    api._lock, api._liveness_lock = threading.Lock(), threading.Lock()
    api._result_transfer_waiters, api._result_send_active, api._last_cj_activity = (), False, None
    api._cell, api._cj_fqcn, api._job_id, api._protocol_secure = transport, CJ, "job1", False
    api._session_id, api._result_abort_signal = be._session.session_id, Signal()
    att = AttachTrainerSession.__new__(AttachTrainerSession)
    att._api, att._task_states, att._task_attempts, att._task_sequences = api, OrderedDict(), {}, {}
    att._evicted_task_sequence, att._current_result_id = 0, None
    api._attach = att
    return api


def run(label, pre_close=False, **kw):
    be = make_cj()
    if pre_close:
        close_task(be)
    tr = Transport(be, **kw)
    api = make_trainer(be, tr)
    try:
        api.send(FLModel(params={"w": np.ones(1024, dtype=np.float32)}))
        outcome = "send() returned normally (trainer: result delivered)"
    except TrainerSessionError as e:
        outcome = f"send() raised TrainerSessionError: {e}"
    with be._task_lock:
        authority = dict(be._result_authority)
    print(f"{label}:")
    for entry in tr.log:
        print("   ", entry)
    print(f"    CJ result authority: {authority or 'none'}")
    print(f"    -> {outcome}")
    return outcome, tr.log, authority


c1 = run("C1 control: task open, replies delivered")
c2 = run("C2 control: task already closed, RESULT_REJECTED delivered", pre_close=True)
c3 = run("C3 control: task already closed, both rejections lost, small result (no lazy transfer)",
         pre_close=True, lose_result_replies=True, lazy=False)
h01 = run("H01: task closes after the CJ's download completed; both RESULT_REJECTED replies lost",
          lose_result_replies=True, close_after_download=True)
ok = ("returned normally" in c1[0] and c1[2]
      and "rejected" in c2[0] and "raised" in c3[0]
      and "returned normally" in h01[0] and not h01[2]
      and [e[1] for e in h01[1] if e[0] == Topic.RESULT_READY] == [Topic.RESULT_REJECTED] * 2
      and all(e[2] == ResultState.UNKNOWN for e in h01[1] if e[0] == Topic.RESULT_STATUS))
print("H01 REPRODUCED: send() reported success although the CJ rejected both attempts and holds no result"
      if ok else "not reproduced")
