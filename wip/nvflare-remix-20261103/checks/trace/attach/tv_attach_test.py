"""v11 block C group-level trace harness (Trainer_A).

Runs the real AttachBackend in a CJ cell with a real trainer process that
attaches over TCP, as upstream tests/integration_test/fast/client_api_attach_e2e_test.py
(test_external_trainer_attaches_and_completes_numpy_task, transport tcp,
trainer-first) does, for two tasks, then finalize. CJ-side events go to
$TV_ATTACH_OUT/<scenario>.json:
  env  launch | input g | stop
  obs  attach | deliver g | publish g | finalize
"""
import json
import os
import subprocess
import sys
import uuid
from unittest.mock import MagicMock

import numpy as np

from nvflare.apis.dxo import DXO, DataKind
from nvflare.apis.signal import Signal
from nvflare.apis.utils.decomposers import flare_decomposers
from nvflare.app_common.app_constant import AppConstants
from nvflare.app_common.decomposers import common_decomposers
from nvflare.app_common.executors.client_api.attach_backend import AttachBackend
from nvflare.app_common.executors.client_api.backend_spec import ClientAPIBackendContext
from nvflare.app_common.np.constants import NPConstants
from nvflare.client.config import ExchangeFormat
from nvflare.fuel.f3.cellnet.cell import Cell
from nvflare.fuel.f3.cellnet.core_cell import CoreCell
from nvflare.fuel.f3.comm_config import CommConfigurator
from nvflare.fuel.f3.drivers.driver_params import DriverParams
from nvflare.fuel.utils.fobs import FOBSContextKey
from nvflare.fuel.utils.network_utils import get_open_ports
from tests.integration_test.fast import client_api_attach_e2e_test as up

OUT = os.environ.get("TV_ATTACH_OUT", "/tmp/tv_attach")


def test_attach_two_tasks(tmp_path, monkeypatch):
    ev = []

    def tr(name, **kw):
        ev.append(dict(ev=name, **kw))

    flare_decomposers.register()
    common_decomposers.register()
    server_url = f"tcp://127.0.0.1:{get_open_ports(1)[0]}"
    suffix = uuid.uuid4().hex[:8]
    site_name, job_id, attach_id = f"site-{suffix}", f"job-{suffix}", f"trainer_{suffix}"
    cells, backend, trainer = [], None, None
    monkeypatch.setattr(CommConfigurator, "_config_loaded", True)
    monkeypatch.setattr(CommConfigurator, "_configuration", {
        "internal": {"scheme": "tcp", "resources": {"host": "127.0.0.1", DriverParams.CONNECTION_SECURITY.value: "clear"}}})
    try:
        server = Cell(f"server-{suffix}", server_url, secure=False, credentials={})
        server.start(); cells.append(server)
        site = Cell(site_name, server_url, secure=False, credentials={}, create_internal_listener=True)
        site.start(); cells.append(site)
        site_listener = up._wait_for_listener(site)
        cj = Cell(f"{site_name}.{job_id}", server_url, secure=False, credentials={}, parent_url=site_listener,
                  create_internal_listener=False)
        cj.start(); cells.append(cj)
        tr("launch")
        profile = tmp_path / "attach_profile.json"
        profile.write_text(json.dumps({"schema_version": 1, "execution_mode": "attach", "attach_id": attach_id,
                                       "site_name": site_name, "job_wait_timeout": 20.0,
                                       "connect_url": site_listener, "connection_security": "clear"}))
        script = tmp_path / "trainer.py"
        script.write_text(up._TRAINER_SCRIPT)
        env = os.environ.copy()
        env["PYTHONPATH"] = up._REPO_ROOT + os.pathsep + env.get("PYTHONPATH", "")
        trainer = subprocess.Popen([sys.executable, "-u", str(script), str(profile)], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, env=env)
        backend = AttachBackend()
        state = {"gen": 0}
        real_deliver = backend._deliver_task

        def deliver(*a, **kw):
            ok, reason = real_deliver(*a, **kw)
            if ok:
                tr("deliver", g=state["gen"])
            return ok, reason

        backend._deliver_task = deliver
        real_accepted = backend._on_result_accepted

        def on_accepted(session, task, result):
            tr("publish", g=state["gen"])
            return real_accepted(session, task, result)

        backend._on_result_accepted = on_accepted
        fl_ctx = up._fl_ctx(cj, site_name, job_id)
        context = ClientAPIBackendContext(executor=MagicMock(), attach_id=attach_id, attach_timeout=20.0,
                                          heartbeat_interval=0.5, heartbeat_timeout=5.0, task_wait_timeout=20.0,
                                          result_wait_timeout=20.0, params_exchange_format=ExchangeFormat.NUMPY,
                                          server_expected_format=ExchangeFormat.NUMPY)
        backend.initialize(context, fl_ctx)
        assert backend._get_session().ready.wait(20.0)
        tr("attach")
        initial = np.arange(16, dtype=np.float32)
        for rnd in range(2):
            state["gen"] = rnd + 1
            tr("input", g=rnd + 1)
            task = DXO(DataKind.WEIGHTS, {NPConstants.NUMPY_KEY: initial}).to_shareable()
            task.set_header(AppConstants.CURRENT_ROUND, rnd)
            task.set_header(FOBSContextKey.RECEIVER_IDS, [site.get_fqcn()])
            result = backend.execute("train", task, fl_ctx, Signal())
            assert result.get_return_code("OK") == "OK", result
            sess = backend._get_session()
            # settle: the trainer's RESULT_SOURCE_SETTLED (private step) before the next task
            for _ in range(200):
                if not sess.result_source_live.is_set():
                    break
                import time
                time.sleep(0.05)
        tr("stop")
        backend.finalize(up._fl_ctx(cj, site_name, job_id))
        tr("finalize")
        backend = None
    finally:
        if backend is not None:
            backend.finalize(up._fl_ctx(cells[-1], site_name, job_id))
        if trainer is not None:
            up._stop_process(trainer)
        for cell in reversed(cells):
            fqcn = cell.get_fqcn()
            cell.stop()
            CoreCell.ALL_CELLS.pop(fqcn, None)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "attach_ok.json"), "w") as f:
        json.dump(ev, f, indent=1)
    assert [e["ev"] for e in ev].count("publish") == 2
