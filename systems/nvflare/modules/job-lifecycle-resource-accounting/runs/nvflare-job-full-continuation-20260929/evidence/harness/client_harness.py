#!/usr/bin/env python3
"""Specula code-analysis verification harness: NVFlare client-side resource / start handlers.

REAL product code exercised (pinned checkout, unmodified):
  - nvflare.private.fed.client.scheduler_cmds: CheckResourceProcessor, StartJobProcessor, CancelResourceProcessor
  - nvflare.private.fed.client.client_engine.ClientEngine.start_app (bound on an instance built with __new__ so that
    no FederatedClient/cell is created; only the attributes start_app reads are set)
  - nvflare.private.fed.client.client_executor.JobExecutor (get_status used by ClientEngine.start_app)
  - nvflare.app_common.resource_managers.list_resource_manager.ListResourceManager (AutoCleanResourceManager base,
    including its expiry thread started by SYSTEM_START) and ListResourceConsumer
  - nvflare.private.fed.client.client_app_runner.ClientAppRunner.notify_job_status
STUBS: a fake FederatedClient/cell for notify_job_status whose send_request returns a non-OK cell reply.
"""
import argparse
import json
import os
import sys
import tempfile
import threading
import time
from types import SimpleNamespace

SOURCE = "/home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/full/source"
import nvflare  # noqa: E402

assert os.path.realpath(nvflare.__file__).startswith(SOURCE), nvflare.__file__

import logging  # noqa: E402

from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.app_common.resource_consumers.list_resource_consumer import ListResourceConsumer  # noqa: E402
from nvflare.app_common.resource_managers.list_resource_manager import ListResourceManager  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode  # noqa: E402
from nvflare.fuel.f3.message import Message as CellMessage  # noqa: E402
from nvflare.private.admin_defs import Message  # noqa: E402
from nvflare.private.defs import RequestHeader, TrainingTopic  # noqa: E402
from nvflare.private.fed.client.client_app_runner import ClientAppRunner  # noqa: E402
from nvflare.private.fed.client.client_engine import ClientEngine  # noqa: E402
from nvflare.private.fed.client.client_executor import JobExecutor  # noqa: E402
from nvflare.private.fed.client.client_status import ClientStatus  # noqa: E402
from nvflare.private.fed.client.scheduler_cmds import (  # noqa: E402
    CancelResourceProcessor,
    CheckResourceProcessor,
    StartJobProcessor,
)
from nvflare.private.scheduler_constants import ShareableHeader  # noqa: E402

logging.basicConfig(level=logging.WARNING)


def make_client_engine(ws_root, rm, consumer):
    for d in ("startup", "local"):
        os.makedirs(os.path.join(ws_root, d), exist_ok=True)
    ce = ClientEngine.__new__(ClientEngine)
    ce.client = SimpleNamespace(
        client_name="site-1",
        components={SystemComponents.RESOURCE_MANAGER: rm, SystemComponents.RESOURCE_CONSUMER: consumer},
    )
    ce.client_name = "site-1"
    ce.args = SimpleNamespace(workspace=ws_root, set=[])
    ce.rank = 0
    ce.logger = logging.getLogger("ClientEngine(harness)")
    ce.client_executor = JobExecutor(SimpleNamespace(client_name="site-1"), os.path.join(ws_root, "startup"))
    ce.fl_ctx_mgr = FLContextManager(engine=ce, identity_name="site-1", job_id="", public_stickers={}, private_stickers={})
    ce.fl_components = [rm]
    return ce


def check(ce, job_id, spec):
    req = Message(topic=TrainingTopic.CHECK_RESOURCE, body=spec)
    req.set_header(RequestHeader.JOB_ID, job_id)
    reply = CheckResourceProcessor().process(req, ce)
    return (reply.body.get_header(ShareableHeader.IS_RESOURCE_ENOUGH),
            reply.body.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN))


def start(ce, job_id, spec, token):
    req = Message(topic=TrainingTopic.START_JOB, body=spec)
    req.set_header(RequestHeader.JOB_ID, job_id)
    req.set_header(RequestHeader.JOB_META, {"job_id": job_id})
    req.set_header(ShareableHeader.RESOURCE_RESERVE_TOKEN, token)
    return StartJobProcessor().process(req, ce).body


def cancel(ce, spec, token):
    req = Message(topic=TrainingTopic.CANCEL_RESOURCE, body=spec)
    req.set_header(ShareableHeader.RESOURCE_RESERVE_TOKEN, token)
    return CancelResourceProcessor().process(req, ce)


def rm_state(rm):
    d = rm.report_resources(None)
    return {"free": d["resources"], "reserved_tokens": len(d["reserved_resources"])}


def scenario_c1(report):
    """START_JOB whose ClientEngine.start_app returns an error STRING (app dir absent) after allocation."""
    ws = tempfile.mkdtemp(prefix="nvf-client-c1-")
    rm = ListResourceManager({"gpu": [0, 1]}, expiration_period=2)
    ce = make_client_engine(ws, rm, ListResourceConsumer())
    ce.fire_event(EventType.SYSTEM_START, ce.new_context())  # starts AutoClean expiry thread (client_train.py:218)
    ok, tok = check(ce, "job-A", {"gpu": 1})
    report["c1_check"] = [ok, bool(tok)]
    report["c1_after_check"] = rm_state(rm)
    body = start(ce, "job-A", {"gpu": 1}, tok)  # app dir for job-A was never deployed / is gone
    report["c1_start_reply"] = body
    report["c1_after_start"] = rm_state(rm)
    time.sleep(4.0)  # > expiration_period ticks: expiry cannot reclaim an allocated (popped) reservation
    report["c1_after_expiry_window"] = rm_state(rm)
    ok2, tok2 = check(ce, "job-B", {"gpu": 2})
    report["c1_later_job_needing_2_units_admitted"] = ok2
    ce.fire_event(EventType.SYSTEM_END, ce.new_context())


def scenario_c3(report):
    """Reservation expiry races with a slow deploy: START after expiry, while another job took the units."""
    ws = tempfile.mkdtemp(prefix="nvf-client-c3-")
    rm = ListResourceManager({"gpu": [0, 1]}, expiration_period=2)
    ce = make_client_engine(ws, rm, ListResourceConsumer())
    ce.fire_event(EventType.SYSTEM_START, ce.new_context())
    ok, tok = check(ce, "job-A", {"gpu": 2})
    time.sleep(3.5)  # job-A deploy slower than expiration_period
    okb, tokb = check(ce, "job-B", {"gpu": 2})
    report["c3_jobB_admitted_after_A_expired"] = okb
    report["c3_state_after_B_reserve"] = rm_state(rm)
    os.makedirs(os.path.join(ws, "job-A", "app_site-1"), exist_ok=True)
    body = start(ce, "job-A", {"gpu": 2}, tok)
    report["c3_jobA_start_reply"] = body
    report["c3_state_after_A_start_attempt"] = rm_state(rm)
    cancel(ce, {"gpu": 2}, tokb)
    report["c3_state_after_B_cancel"] = rm_state(rm)
    ce.fire_event(EventType.SYSTEM_END, ce.new_context())


def scenario_c4(report):
    """free_resources has no ownership/token check: a duplicate free duplicates units (defensive-gap probe)."""
    rm = ListResourceManager({"gpu": [0, 1]}, expiration_period=30)
    ok, tok = rm.check_resources({"gpu": 1}, None)
    alloc = rm.allocate_resources({"gpu": 1}, tok, None)
    rm.free_resources(alloc, tok, None)
    rm.free_resources(alloc, tok, None)
    report["c4_after_double_free"] = rm_state(rm)
    a1 = rm.allocate_resources({"gpu": 2}, rm.check_resources({"gpu": 2}, None)[1], None)
    a2 = rm.allocate_resources({"gpu": 1}, rm.check_resources({"gpu": 1}, None)[1], None)
    report["c4_two_live_allocations"] = [a1, a2]


def scenario_c2(report):
    """notify_job_status keeps retrying past retry_timeout (docstring: stop at retry_timeout)."""
    tries = {"n": 0}

    class FakeCell:
        def send_request(self, **kw):
            tries["n"] += 1
            time.sleep(0.05)
            m = CellMessage()
            m.set_header(MessageHeaderKey.RETURN_CODE, ReturnCode.TIMEOUT)
            return m

    fc = SimpleNamespace(cell=SimpleNamespace(core_cell=SimpleNamespace(get_fqcn=lambda: "site-1.job-A")))
    fc.cell.send_request = FakeCell().send_request
    runner = ClientAppRunner()
    done = threading.Event()

    def target():
        runner.notify_job_status(fc, "job-A", ClientStatus.STARTED, timeout=0.05, retry_timeout=1.0)
        done.set()

    th = threading.Thread(target=target, daemon=True)
    th.start()
    th.join(timeout=6.0)
    report["c2_returned_within_6s_with_retry_timeout_1s"] = done.is_set()
    report["c2_send_attempts_in_6s"] = tries["n"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    report = {}
    for fn in (scenario_c1, scenario_c3, scenario_c4, scenario_c2):
        try:
            fn(report)
        except Exception as e:
            report[fn.__name__ + "_error"] = f"{type(e).__name__}: {e}"
    txt = json.dumps(report, indent=2, default=str)
    print(txt)
    with open(a.out, "w") as f:
        f.write(txt + "\n")
    os._exit(0)


if __name__ == "__main__":
    main()
