"""v11 block F group-level trace harness (JobCP_C under multiJobCP).

The real ListResourceManager (AutoCleanResourceManager) of one CP with a single
GPU unit serves two jobs: J2 checks, allocates, later frees the unit; our job's
CHECK_RESOURCES finds it busy, then available. Events go to
$TV_MJCP_OUT/<scenario>.json:
  env  check n        (our job's CHECK_RESOURCES request number n)
  obs  j2start | checkno | j2exit | j2free | checkok
"""
import json
import os

from nvflare.apis.fl_context import FLContext
from nvflare.app_common.resource_managers.list_resource_manager import ListResourceManager

OUT = os.environ.get("TV_MJCP_OUT", "/tmp/tv_mjcp")


def test_second_job_holds_the_unit():
    ev = []
    tr = lambda name, **kw: ev.append(dict(ev=name, **kw))
    rm = ListResourceManager(resources={"gpu": [0]}, expiration_period=30)
    ctx = FLContext()
    req = {"gpu": 1}
    ok2, tok2 = rm.check_resources(req, ctx)          # J2's START pipeline: check, then allocate
    assert ok2
    alloc2 = rm.allocate_resources(req, tok2, ctx)
    assert alloc2
    tr("j2start")
    tr("check", n=1)
    ok, tok = rm.check_resources(req, ctx)            # our job's CHECK_RESOURCES
    assert not ok
    tr("checkno")
    tr("j2exit")
    rm.free_resources(alloc2, tok2, ctx)              # J2's CJ ended: its allocation is freed
    tr("j2free")
    tr("check", n=2)
    ok, tok = rm.check_resources(req, ctx)
    assert ok and tok
    tr("checkok")
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "mjcp_ok.json"), "w") as f:
        json.dump(ev, f, indent=1)
