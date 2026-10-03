#!/usr/bin/env python3
"""Reproduce CR-22: re-registration changes a site token while a job keeps the old participant token."""

import sys
import uuid
from contextlib import nullcontext
from pathlib import Path
from unittest.mock import MagicMock, patch


REPO = Path(__file__).resolve().parents[1] / "confirmation" / "CR-22" / "worktree"
sys.path.insert(0, str(REPO))

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.fl_constant import RunProcessKey  # noqa: E402
from nvflare.apis.fl_context import FLContext  # noqa: E402
from nvflare.apis.shareable import Shareable  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.private.defs import CellMessageHeaderKeys, ClientType, new_cell_message  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402


PROJECT = "project"
SITE = "site-1"
JOB_ID = "job-1"
BASE_UUID = uuid.UUID("00000000-0000-0000-0000-000000000000")
OLD_UUID = uuid.UUID("00000000-0000-0000-0000-000000000001")
NEW_UUID = uuid.UUID("00000000-0000-0000-0000-000000000002")


def _new_context():
    return nullcontext(FLContext())


def _make_server():
    args = MagicMock()
    args.workspace = "/tmp/cr22-workspace"
    args.config_folder = "startup"

    server = FederatedServer(
        project_name=PROJECT,
        min_num_clients=1,
        max_num_clients=10,
        cmd_modules=None,
        heart_beat_timeout=600,
        args=args,
        secure_train=False,
        snapshot_persistor=MagicMock(),
    )
    server.server_state = HotState()
    server._get_id_asserter = lambda: None
    server.engine.new_context.side_effect = _new_context
    server.engine.run_processes = {}
    server.engine.exception_run_processes = {}
    server.engine.job_runner.get_client_outcome_jobs.return_value = set()

    notifications = []

    def _notify(job_id, client_name, reason):
        notifications.append((job_id, client_name, reason))

    server.engine.notify_dead_job.side_effect = _notify
    return server, notifications


def _register_request(site_name):
    shareable = Shareable()
    shareable.set_peer_context(FLContext())
    return new_cell_message(
        {
            CellMessageHeaderKeys.PROJECT_NAME: PROJECT,
            CellMessageHeaderKeys.CLIENT_NAME: site_name,
            CellMessageHeaderKeys.CLIENT_TYPE: ClientType.REGULAR,
            CellMessageHeaderKeys.CLIENT_IP: "127.0.0.1",
            MessageHeaderKey.ORIGIN: f"{site_name}.fqcn",
        },
        shareable,
    )


def _heartbeat_request(site_name, token, job_ids):
    shareable = Shareable()
    shareable.set_peer_context(FLContext())
    return new_cell_message(
        {
            CellMessageHeaderKeys.TOKEN: token,
            CellMessageHeaderKeys.PROJECT_NAME: PROJECT,
            CellMessageHeaderKeys.CLIENT_NAME: site_name,
            CellMessageHeaderKeys.JOB_IDS: list(job_ids),
            MessageHeaderKey.ORIGIN: f"{site_name}.fqcn",
        },
        shareable,
    )


def _register(server, site_name):
    reply = server.register_client(_register_request(site_name))
    token = reply.payload[CellMessageHeaderKeys.TOKEN]
    client = server.client_manager.clients[token]
    return token, client


def _install_running_job(server, token, client):
    server.engine.run_processes = {JOB_ID: {RunProcessKey.PARTICIPANTS: {token: client}}}


def _positive_heartbeat(server, token):
    reply = server.client_heartbeat(_heartbeat_request(SITE, token, [JOB_ID]))
    rc = reply.get_header(MessageHeaderKey.RETURN_CODE)
    if rc != "ok":
        raise AssertionError(f"positive heartbeat returned {rc!r}")


def _missing_job_heartbeat(server, token):
    return server.client_heartbeat(_heartbeat_request(SITE, token, []))


def baseline_same_token_notifies():
    server, notifications = _make_server()
    token, client = _register(server, SITE)
    _install_running_job(server, token, client)
    _positive_heartbeat(server, token)
    _missing_job_heartbeat(server, token)
    if notifications != [(JOB_ID, SITE, "missing job on client")]:
        raise AssertionError(f"baseline expected one dead-job notification, got {notifications!r}")
    return notifications


def trigger_reregistration_token_split():
    server, notifications = _make_server()
    old_token, old_client = _register(server, SITE)
    _install_running_job(server, old_token, old_client)
    _positive_heartbeat(server, old_token)

    new_token, new_client = _register(server, SITE)
    if old_token == new_token:
        raise AssertionError("re-registration did not issue a new token")
    if old_token in server.client_manager.clients:
        raise AssertionError("old token unexpectedly remained active after re-registration")
    if new_token not in server.client_manager.clients:
        raise AssertionError("new token was not active after re-registration")

    for _ in range(3):
        _missing_job_heartbeat(server, new_token)

    after_heartbeats = list(notifications)
    server.notify_dead_client(new_client)
    after_dead_cleanup = list(notifications)

    return {
        "old_token": old_token,
        "new_token": new_token,
        "participant_tokens": list(server.engine.run_processes[JOB_ID][RunProcessKey.PARTICIPANTS].keys()),
        "active_tokens": list(server.client_manager.clients.keys()),
        "after_heartbeats": after_heartbeats,
        "after_dead_cleanup": after_dead_cleanup,
    }


def main():
    print("CR-22 reproduction: same-site re-registration leaves running-job participants keyed by old token")
    with (
        patch("nvflare.private.fed.server.fed_server.ServerEngine"),
        patch("nvflare.private.fed.server.fed_server.ConfigService.get_bool_var", return_value=True),
    ):
        with patch(
            "nvflare.private.fed.server.client_manager.uuid.uuid4",
            side_effect=[BASE_UUID, OLD_UUID, NEW_UUID],
        ):
            baseline = baseline_same_token_notifies()
            result = trigger_reregistration_token_split()

    print(f"CONTROL same-token missing-job notifications: {baseline}")
    print(f"TRIGGER old token from first registration: {result['old_token']}")
    print(f"TRIGGER new token from re-registration: {result['new_token']}")
    print(f"TRIGGER job participant tokens: {result['participant_tokens']}")
    print(f"TRIGGER active client-manager tokens: {result['active_tokens']}")
    print(f"TRIGGER notifications after 3 new-token no-job heartbeats: {result['after_heartbeats']}")
    print(f"TRIGGER notifications after notify_dead_client(new client): {result['after_dead_cleanup']}")

    bug_reproduced = not result["after_heartbeats"] and not result["after_dead_cleanup"]
    if not bug_reproduced:
        print("BUG NOT REPRODUCED: a downstream path emitted a dead-job notification")
        return 1

    print("BUG REPRODUCED: re-registered site is active, but token-keyed participant lookup suppresses dead-job notification")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
