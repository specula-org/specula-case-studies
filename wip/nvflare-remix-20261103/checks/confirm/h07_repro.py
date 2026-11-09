"""H07 (Phase 1 candidate, v11 V6): a slow publish_results handler of an old CJ launch
removes the workspace-transfer record that the replacement launch registered, so the
replacement's results are rejected. Pinned source c411a201, read-only via sys.path.

Real code: WorkspaceTransferManager (add_job, the publish_results handler with
_authorize, extraction and remove_job(job_id), workspace_cell_transfer.py:333-487).
Stubs: the cell (callbacks are called directly) and download_file, which writes a
real results zip; for the old launch it blocks until the replacement has registered
(forced timing: the handler's download outlives its requester, the slow-handler
premise of Phase 1 H07). Control: without the overlap the replacement publishes.
"""
import os, sys, tempfile, threading, zipfile

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)
from nvflare.app_opt.job_launcher import workspace_cell_transfer as wct  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode  # noqa: E402
from nvflare.fuel.f3.cellnet.utils import new_cell_message  # noqa: E402


class Cell:
    def __init__(self):
        self.cbs = {}

    def get_fqcn(self):
        return "site-1"

    def register_request_cb(self, channel, topic, cb):
        self.cbs[topic] = cb


def scenario(overlap):
    tmp = tempfile.mkdtemp(prefix="h07-", dir=os.environ.get("TMPDIR"))
    job = "job-1"
    gate, entered = threading.Event(), threading.Event()

    def download_file(from_fqcn, ref_id, per_request_timeout, cell, location):
        path = os.path.join(location, "r.zip")
        with zipfile.ZipFile(path, "w") as zf:
            zf.writestr(f"{job}/{ref_id}.txt", ref_id)
        if ref_id == "old" and overlap:
            entered.set()
            gate.wait(10)                 # the old launch's download is still running
        return None, path

    wct.download_file = download_file
    wct._validate_job_zip_members = lambda zf, jid: None
    cell = Cell()
    mgr = wct.WorkspaceTransferManager(cell)
    publish = cell.cbs[wct.TOPIC_PUBLISH_RESULTS]

    def req(origin, token, ref):
        return new_cell_message({MessageHeaderKey.ORIGIN: origin}, {"job_id": job, "transfer_token": token, "ref_id": ref})

    tok1 = mgr.add_job(job, os.path.join(tmp, "ws"))                  # launch 1 registered by launch_job
    out = {}
    t = threading.Thread(target=lambda: out.setdefault("old", publish(req("site-1.job-1", tok1, "old"))))
    t.start()
    if overlap:
        entered.wait(10)                  # authorized against launch 1's record, download in progress
        # launch 1's CJ is gone (its request timed out / it was killed); the CP relaunches:
        tok2 = mgr.add_job(job, os.path.join(tmp, "ws"))             # launch 2 registers a new record
        gate.set()
        t.join()
    else:
        t.join()
        tok2 = mgr.add_job(job, os.path.join(tmp, "ws"))
    rep2 = publish(req("site-1.job-1", tok2, "new"))                   # launch 2 publishes its results
    rc_old = out["old"].get_header(MessageHeaderKey.RETURN_CODE)
    rc_new = rep2.get_header(MessageHeaderKey.RETURN_CODE)
    return rc_old, rc_new, (rep2.payload if rc_new != ReturnCode.OK else "")


ctl = scenario(overlap=False)
h07 = scenario(overlap=True)
print("control (no overlap):          old publish rc:", ctl[0], "| replacement publish rc:", ctl[1])
print("old handler outlives relaunch: old publish rc:", h07[0], "| replacement publish rc:", h07[1], "|", h07[2])
ok = ctl[1] == ReturnCode.OK and h07[1] != ReturnCode.OK
print("H07 REPRODUCED (forced timing): the replacement launch's results are rejected after the old handler"
      " removed its record" if ok else "not reproduced")
