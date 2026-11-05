"""H30 sub-claim confirmation against the pinned DownloadService (c411a201):
the SJ's own DownloadService.shutdown() converts only downloads that are ACTIVE
at shutdown time into a typed DownloadCancelled. A download_object() that
starts after shutdown (late streamed SUBMIT_UPDATE decode) is not covered by
any latch, so a source-gone reply is reported as a plain failure -- the path
that cell.py:118-135 turns into os._exit(1) in a server job cell.
Fake cell: request callbacks are no-ops; every data request is answered with
INVALID_REQUEST (the straggler CJ's own DownloadService was shut down)."""
import sys, threading
sys.path.insert(0, "/home/ubuntu/nvflare-integrated-model-20261103/sources/current")
sys.dont_write_bytecode = True
from nvflare.fuel.f3.streaming.download_service import DownloadService, download_object, Consumer
from nvflare.fuel.f3.streaming.stream_types import DownloadCancelled
from nvflare.fuel.f3.message import Message
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode

class FakeCell:
    def __init__(self, gate=None):
        self.gate = gate
    def register_request_cb(self, *a, **k): pass
    def __getattr__(self, n):           # any other registration hook: no-op
        return lambda *a, **k: None
    def send_request(self, **kw):
        if self.gate:                    # block until the test releases the request
            self.gate.wait(5)
        return Message(headers={MessageHeaderKey.RETURN_CODE: ReturnCode.INVALID_REQUEST}, payload=None)
    def fire_and_forget(self, **kw): return {}

class C(Consumer):
    def __init__(self): super().__init__(); self.failed = None
    def consume(self, ref_id, state, data): return state
    def download_completed(self, ref_id): pass
    def download_failed(self, ref_id, reason): self.failed = reason

def run(cell, ref):
    c = C()
    try:
        download_object(from_fqcn="site-1.job1", ref_id=ref, per_request_timeout=1.0, cell=cell, consumer=c, max_retries=0)
        return ("returned (plain failure -> FOBS RuntimeError -> os._exit in SJ cell)", c.failed)
    except DownloadCancelled as e:
        return ("raised DownloadCancelled (typed; SJ replies SERVICE_UNAVAILABLE)", str(e))

# A: download active when the SJ's DownloadService shuts down
gate = threading.Event(); res = {}
t = threading.Thread(target=lambda: res.setdefault("A", run(FakeCell(gate), "refA"))); t.start()
import time; time.sleep(0.3)
DownloadService.shutdown(); gate.set(); t.join(5)
# B: download that starts AFTER the shutdown (late submission decode)
res["B"] = run(FakeCell(), "refB")
for k in ("A", "B"):
    print(k, res[k][0], "|", res[k][1])
