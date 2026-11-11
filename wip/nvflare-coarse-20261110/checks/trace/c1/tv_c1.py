"""Chunk-1 group-level trace harness (Reg admin operations, cleanup logout, heartbeat
re-activation; Login: a restarted CP's registration and connect-thread wait).

Real code: ClientManager (authenticate, heartbeat, remove_client, disable_client,
enable_client, is_client_disabled), ServerEngine.remove_clients / disable_clients /
enable_clients / _remove_dead_client, FederatedServer.remove_dead_clients / logout_client,
FederatedClientBase (connect_to_server, _create_cell's engine wait, client_register,
set_client_engine), Communicator.client_registration, Authenticator.authenticate.
Stubs: the auth-header filters on the cell (STANDARD 8), the server object around ClientManager (remove_client_data, admin server,
notify_dead_client records the notification), the f3 Cell (send_request hands a Register
request to the real ClientManager.authenticate and replies as fed_server.register_client
does), wait_for_server, NetAgent, mpm cleanup hooks, the client engine (records
register_cell_cb). Time: a client's staleness is set by moving last_connect_time back.
Port-level events go to $TV_C1_OUT/<scenario>.json:
  env  launch | cprestart c
  obs  remove c | disable c | enable c | reactivate c | stale c | logout c | notify c |
       relogin c | begin c | up c | updeaf c | exit c
"""
import json
import os
import sys
import threading
import time
import types

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)
from nvflare.apis.fl_constant import ConnPropKey, FLContextKey, ReturnCode  # noqa: E402
from nvflare.apis.fl_context import FLContext  # noqa: E402
from nvflare.apis.shareable import Shareable  # noqa: E402
from nvflare.fuel.data_event.utils import set_scope_property  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey
from nvflare.fuel.f3.cellnet.defs import ReturnCode as F3RC  # noqa: E402
from nvflare.fuel.f3.message import Message as CellMessage  # noqa: E402
from nvflare.private.defs import CellMessageHeaderKeys, ClientType  # noqa: E402
import nvflare.private.fed.client.communicator as comm_mod  # noqa: E402
import nvflare.private.fed.client.fed_client_base as fcb_mod  # noqa: E402
from nvflare.private.fed.client.fed_client_base import FederatedClientBase  # noqa: E402
from nvflare.private.fed.server.client_manager import ClientManager  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.server_engine import ServerEngine  # noqa: E402

OUT = os.environ.get("TV_C1_OUT", os.path.join(os.path.dirname(os.path.abspath(__file__)), "traces"))
PROJECT = "proj"


class Tracer:
    def __init__(self):
        self.ev = []

    def __call__(self, ev, c=None):
        e = {"ev": ev}
        if c is not None:
            e["c"] = c
        self.ev.append(e)

    def save(self, name):
        os.makedirs(OUT, exist_ok=True)
        with open(os.path.join(OUT, name + ".json"), "w") as f:
            json.dump(self.ev, f, indent=1)


def login_request(name):
    req = CellMessage(
        headers={
            CellMessageHeaderKeys.CLIENT_NAME: name,
            CellMessageHeaderKeys.CLIENT_TYPE: ClientType.REGULAR,
            CellMessageHeaderKeys.PROJECT_NAME: PROJECT,
            CellMessageHeaderKeys.CLIENT_IP: "127.0.0.1",
        },
        payload=Shareable(),
    )
    return req


class Server:
    """The SP side: the real ClientManager inside a minimal server / engine shell."""

    def __init__(self, tr):
        self.tr = tr
        self.cm = ClientManager(project_name=PROJECT, min_num_clients=1, max_num_clients=10)
        self.notified = []
        srv = types.SimpleNamespace(client_manager=self.cm, admin_server=None, heart_beat_timeout=60.0,
                                    logger=self.cm.logger)
        srv.remove_client_data = lambda token: None
        srv.notify_dead_client = lambda client: (self.notified.append(client.name), tr("notify", client.name))
        srv.logout_client = lambda token: FederatedServer.logout_client(srv, token)
        self.srv = srv
        eng = types.SimpleNamespace(server=srv)
        eng._remove_dead_client = lambda token: ServerEngine._remove_dead_client(eng, token)
        self.eng = eng

    def register(self, name):
        fl_ctx = FLContext()
        client = self.cm.authenticate(login_request(name), fl_ctx)
        return client, fl_ctx

    def token_of(self, name):
        c = self.cm.get_client_from_name(name)
        return c.token if c else None

    def remove(self, token, name):
        ServerEngine.remove_clients(self.eng, [token])
        self.tr("remove", name)

    def disable(self, name):
        ServerEngine.disable_clients(self.eng, [name])
        self.tr("disable", name)

    def enable(self, name):
        ServerEngine.enable_clients(self.eng, [name])
        self.tr("enable", name)

    def heartbeat(self, token, name):
        """fed_server.client_heartbeat: disabled names are rejected before the manager."""
        if self.cm.is_client_disabled(name):
            return "rejected"
        fl_ctx = FLContext()
        if self.cm.heartbeat(token, name, name, fl_ctx):
            self.tr("reactivate", name)
            return "reactivated"
        return "ok"

    def go_stale(self, name):
        c = self.cm.get_client_from_name(name)
        c.last_connect_time = time.time() - 3600
        self.tr("stale", name)

    def cleanup_pass(self):
        before = set(self.cm.get_clients())
        FederatedServer.remove_dead_clients(self.srv)
        return before - set(self.cm.get_clients())


# ------------------------------------------------------------------ Reg scenarios
def reg_remove_live():
    """happy path: an admin removes a live client's token while its job runs; its next
    heartbeat re-activates the same token."""
    tr = Tracer(); s = Server(tr)
    cl, _ = s.register("site-1"); tok = cl.token
    tr("launch")
    s.remove(tok, "site-1")
    assert s.heartbeat(tok, "site-1") == "reactivated"
    assert s.token_of("site-1") == tok
    tr.save("reg_remove_live")


def reg_dead_cleanup():
    """happy path: a client's heartbeats stop, the cleanup thread logs it out and notifies."""
    tr = Tracer(); s = Server(tr)
    s.register("site-1")
    tr("launch")
    s.go_stale("site-1")
    gone = s.cleanup_pass()
    tr.ev.insert(len(tr.ev) - 1, {"ev": "logout", "c": "site-1"})   # logout_client: remove, then notify
    assert len(gone) == 1 and s.notified == ["site-1"]
    tr.save("reg_dead_cleanup")


def reg_dead_admin_remove():
    """error path: the client is dead (stale) and an admin removes its token before the
    cleanup thread runs: the cleanup pass finds nothing, no notification is ever sent."""
    tr = Tracer(); s = Server(tr)
    cl, _ = s.register("site-1"); tok = cl.token
    tr("launch")
    s.go_stale("site-1")
    s.remove(tok, "site-1")
    gone = s.cleanup_pass()
    assert not gone and s.notified == []
    tr.save("reg_dead_admin_remove")


def reg_disable_enable():
    """error path: an admin disables a participant while its job runs (heartbeats rejected),
    then enables it; the next heartbeat re-activates the token."""
    tr = Tracer(); s = Server(tr)
    cl, _ = s.register("site-1"); tok = cl.token
    tr("launch")
    s.disable("site-1")
    assert s.heartbeat(tok, "site-1") == "rejected"
    assert s.cleanup_pass() == set() and s.notified == []
    s.enable("site-1")
    assert s.heartbeat(tok, "site-1") == "reactivated"
    tr.save("reg_disable_enable")


# ------------------------------------------------------------------ Login scenarios
class StubCell:
    def __init__(self, server, delay, tr, name):
        self.server, self.delay, self.tr, self.name = server, delay, tr, name

    def start(self):
        pass

    def __getattr__(self, name):            # callback registration and other cell plumbing: no-ops
        return lambda *a, **k: None

    def change_server_root(self, url):
        pass

    def send_request(self, target, channel, topic, request, timeout=None, optional=False, **kw):
        if self.delay:
            time.sleep(self.delay)
        client, fl_ctx = self.server.register(self.name)     # as fed_server.register_client
        if not client:
            reply = CellMessage(headers={}, payload=None)
            reply.set_header(MessageHeaderKey.RETURN_CODE, F3RC.UNAUTHENTICATED)
            reply.set_header(MessageHeaderKey.ERROR, fl_ctx.get_prop(FLContextKey.UNAUTHENTICATED, "?"))
            return reply
        self.tr("relogin", self.name)
        reply = CellMessage(headers={}, payload={CellMessageHeaderKeys.TOKEN: client.token,
                                                 CellMessageHeaderKeys.SSID: "ssid"})
        reply.set_header(MessageHeaderKey.RETURN_CODE, F3RC.OK)
        return reply


def cp_start(tr, server, name, reg_delay, engine_timeout):
    """client_train.main's order: connect thread; wait for the cell; register; engine and
    admin agent; the connect thread registers the admin channel once the engine exists."""
    set_scope_property(name, ConnPropKey.CP_CONN_PROPS, {ConnPropKey.FQCN: name, ConnPropKey.URL: "tcp://cp"})
    fcb_mod.wait_for_server = lambda **kw: None
    fcb_mod.Cell = lambda **kw: StubCell(server, reg_delay, tr, name)
    fcb_mod.NetAgent = lambda cell: types.SimpleNamespace(close=lambda: None)
    fcb_mod.mpm = types.SimpleNamespace(add_cleanup_cb=lambda cb: None)
    comm_mod.set_add_auth_headers_filters = lambda *a, **k: None   # auth header filters (STANDARD 8)
    args = types.SimpleNamespace(job_id=None)
    client = FederatedClientBase(client_name=name, client_args={"engine_create_timeout": engine_timeout},
                                 secure_train=False, server_args={PROJECT: {}}, args=args)
    tr("begin", name)
    err = []

    def _connect():
        try:
            client.connect_to_server(PROJECT, "sp:8002", "tcp")
        except BaseException as e:
            err.append(e)
    th = threading.Thread(target=_connect, daemon=True); th.start()
    while client.cell is None:
        time.sleep(0.01)
    fl_ctx = FLContext()
    client.register(fl_ctx)
    if not client.token:
        tr("exit", name)                     # main: "Login failed", the CP exits
        return client, err, None
    registered = []
    engine = types.SimpleNamespace(cell=None, admin_agent=types.SimpleNamespace(
        register_cell_cb=lambda: registered.append(True)))
    client.set_client_engine(engine)         # create_admin_agent
    th.join(timeout=engine_timeout + 2)
    tr("up" if registered else "updeaf", name)
    return client, err, registered


def login_ok():
    tr = Tracer(); s = Server(tr)
    s.register("site-1")
    tr("cprestart", "site-1")
    client, err, reg = cp_start(tr, s, "site-1", reg_delay=0.0, engine_timeout=2.0)
    assert reg and not err
    tr.save("login_ok")


def login_slow():
    """error path: registration outlasts engine_create_timeout: the CP registers and would
    heartbeat, but its admin channel is never registered."""
    tr = Tracer(); s = Server(tr)
    s.register("site-1")
    tr("cprestart", "site-1")
    client, err, reg = cp_start(tr, s, "site-1", reg_delay=1.5, engine_timeout=0.5)
    assert client.token and not reg and err, (client.token, reg, err)
    tr.save("login_slow")


def login_disabled():
    """error path: the client name is disabled while the CP restarts: registration is
    rejected and the CP exits."""
    tr = Tracer(); s = Server(tr)
    s.register("site-1")
    s.disable("site-1")
    tr("cprestart", "site-1")
    client, err, reg = cp_start(tr, s, "site-1", reg_delay=0.0, engine_timeout=1.0)
    assert client.token is None
    tr.save("login_disabled")


if __name__ == "__main__":
    for f in (reg_remove_live, reg_dead_cleanup, reg_dead_admin_remove, reg_disable_enable,
              login_ok, login_slow, login_disabled):
        f()
        print(f.__name__, "ok", flush=True)
