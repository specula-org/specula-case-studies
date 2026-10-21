"""Adapter checks only: hand-authored source schedules, not kernel evidence."""

import copy
import json
from pathlib import Path

OUT = Path(__file__).resolve().parent


def local():
    return dict(pc="Idle", kind="read", O=0, N=0, target=0, fault=0,
                S=0, K=0, copyO=0, candidate=0, D=0, status="Pending",
                errorSite="none", result=-1, ioKind="Read", ioOff=0,
                ioLen=0, ioDone=0, ioEnd=0, page=0, afterIo="BackendReturn",
                resizeOld=0, resizeNew=0, resizePurpose="resize",
                afterResize="BackendReturn", segmentEnd=0, collectNext=0,
                collectEnd=0, overwrite=False, out=["sentinel"] * 6)


class Fixture:
    def __init__(self, threads):
        self.data = dict(format="asterinas-buffered-v1",
                         revision="604948581512d83734377974d4c34adb4530f2d7",
                         backend="ramfs", p=2, g=2, max_byte=6,
                         initial_size=2, warm_pages=[0], initial_position=0,
                         threads=threads, traces={t: [] for t in threads})
        self.locals = {t: local() for t in threads}
        self.held = {t: dict(cache=False, writer=False, up=False,
                             reader=False, offset=False) for t in threads}
        self.tick = 0

    def emit(self, tid, event, *, change=None, held=None, args=None,
             inode=None, pages=None, position=None, interval=None):
        self.locals[tid].update(change or {})
        self.held[tid].update(held or {})
        self.tick += 2
        start, end = interval or (self.tick, self.tick + 1)
        state = dict(local=copy.deepcopy(self.locals[tid]), accepted=[],
                     held=dict(self.held[tid]), inode=inode or {},
                     pages=pages or [], disk=[], blocks=[],
                     position=[] if position is None else [position])
        self.data["traces"][tid].append(dict(tag="trace", tid=tid, event=event,
                                              start=start, end=end,
                                              args=args or [], state=state))

    def enter_read(self, interval=None):
        self.emit("r", "SyscallEnter", change=dict(pc="Dispatch", N=2, fault=2),
                  held=dict(offset=True), args=["read", 0, 2, 0, 2],
                  position=0, interval=interval)

    def observe_read(self):
        self.emit("r", "RamfsReadAtObserve", change=dict(pc="RamReadCache", S=2, K=2))

    def acquire_read(self):
        self.emit("r", "RamfsReadAtAcquireCache", change=dict(pc="VmoBegin", ioLen=2),
                  held=dict(cache=True))

    def return_read(self):
        self.emit("r", "BackendReturn", change=dict(pc="Return", status="Ok", result=2),
                  held=dict(cache=False))
        self.emit("r", "InodeHandleReturn", change=dict(pc="Done"),
                  held=dict(offset=False), position=2)

    def write(self, name):
        (OUT / name).write_text(json.dumps(self.data) + "\n")


normal = Fixture(["r"])
normal.enter_read()
normal.observe_read()
normal.acquire_read()
normal.emit("r", "VmoIoBegin", change=dict(pc="CollectBegin", ioEnd=2))
normal.emit("r", "VmoCollectBegin", change=dict(pc="CommitPage", segmentEnd=2, collectEnd=1))
normal.emit("r", "VmoCommitPage", change=dict(pc="CollectedPage"),
            pages=[dict(index=0, state="Clean", data=["seed", "seed"])])
normal.emit("r", "VmoCollectedPage", change=dict(pc="CopyPage", collectNext=1))
normal.emit("r", "VmoCopyPage", change=dict(pc="BackendReturn", ioDone=2, D=2,
                                           out=["seed", "seed"] + ["sentinel"] * 4))
normal.return_read()
normal.write("synthetic-read.ndjson")

race = Fixture(["r", "w"])
race.enter_read(interval=(1, 3))
race.emit("w", "SyscallEnter", change=dict(pc="Dispatch", kind="ftruncate"),
          args=["ftruncate", 0, 0, 0, 0], interval=(1, 3))
race.observe_read()
race.emit("w", "RamfsResizeAcquireCache", change=dict(pc="RamResizeMetadata"), held=dict(cache=True))
race.emit("w", "RamfsResize", change=dict(pc="ResizeBegin", S=2, resizeOld=2,
                                         afterResize="RamResizePublish"), inode=dict(L=2))
race.emit("w", "PageCacheResizeBegin", change=dict(pc="ResizeCapacity", ioKind="Zero", afterIo="ResizeCapacity"))
race.emit("w", "PageCacheResizeCapacity", change=dict(pc="RamResizePublish"),
          inode=dict(C=0), pages=[dict(index=0, state="Absent", data=["uninit", "uninit"])])
race.emit("w", "RamfsResizePublish", change=dict(pc="BackendReturn"), inode=dict(L=0))
race.emit("w", "BackendReturn", change=dict(pc="Return", status="Ok", result=0), held=dict(cache=False))
race.emit("w", "InodeHandleReturn", change=dict(pc="Done"))
race.acquire_read()
race.emit("r", "VmoIoBegin", change=dict(pc="BackendReturn"))
race.return_read()
race.write("synthetic-shrink-overlap.ndjson")

for field, value in [("K", 1), ("D", 1), ("out", ["zero"] * 6)]:
    bad = copy.deepcopy(normal.data)
    event = next(e for e in bad["traces"]["r"] if e["event"] == "VmoCopyPage")
    event["state"]["local"][field] = value
    (OUT / f"synthetic-bad-{field}.ndjson").write_text(json.dumps(bad) + "\n")
bad = copy.deepcopy(race.data)
event = next(e for e in bad["traces"]["w"] if e["event"] == "PageCacheResizeCapacity")
event["state"]["inode"]["C"] = 2
(OUT / "synthetic-bad-capacity.ndjson").write_text(json.dumps(bad) + "\n")
bad = copy.deepcopy(normal.data)
event = next(e for e in bad["traces"]["r"] if e["event"] == "RamfsReadAtAcquireCache")
event["state"]["held"]["cache"] = False
(OUT / "synthetic-bad-lock.ndjson").write_text(json.dumps(bad) + "\n")
