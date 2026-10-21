#!/usr/bin/env python3
"""Post-hoc analysis of the CR-2 repro guest log: prove (or disprove) that the
hypothesized queue-selection vs ancillary-publication interleaving occurred in
the instrumented V1 rounds, and that the CR-2 properties held while it did.

For each instrumented V1 round (case 1000+round, tids: 1=peek, 2=recv, 0=main)
the interesting pattern is:
  - tid1 (peek)  MessageReceiverTryRecvSelect.start
        < tid2 (recv) MessageReceiverTryRecvDequeue.start
    (peek selected the message before the recv consumed it), AND
  - tid1 FileTableInsert.end > tid2 MessageReceiverTryRecvDequeue.start
    (peek published its cloned references AFTER the message was consumed).
The strongest form also checks tid1's last publication event ending after
tid2's SysRecvmsgComplete (peek published after the recv finished publishing).
"""
import json
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "guest.log"
raw = re.compile(r'SCM_RAW (\{.*\})')
events = []
for line in open(path, errors="replace"):
    m = raw.search(line)
    if not m:
        continue
    try:
        events.append(json.loads(m.group(1)))
    except json.JSONDecodeError:
        pass

by_round = {}
for e in events:
    by_round.setdefault(e["case"], {}).setdefault(e["tid"], []).append(e)

def span(evs, name):
    for e in evs:
        if e["event"] == name:
            return (e["start"], e["end"])
    return None

interleaved = strong = rounds_with_both = 0
details = []
for case, threads in sorted(by_round.items()):
    if case < 1000 or case >= 2000:
        continue
    t1 = threads.get(1, [])
    t2 = threads.get(2, [])
    sel = span(t1, "MessageReceiverTryRecvSelect")
    deq = span(t2, "MessageReceiverTryRecvDequeue")
    if not sel or not deq:
        continue  # peek or recv failed (EAGAIN): no interleaving window
    rounds_with_both += 1
    inserts = [e for e in t1 if e["event"] == "FileTableInsert"]
    completes = [e for e in t2 if e["event"] == "SysRecvmsgComplete"]
    if not inserts or not completes:
        continue
    pub_after_consume = max(e["end"] for e in inserts) > deq[0]
    pub_after_recv_done = max(e["end"] for e in inserts) > completes[-1]["start"]
    if sel[0] < deq[0] and pub_after_consume:
        interleaved += 1
        if pub_after_recv_done:
            strong += 1
        details.append((case, sel[0], deq[0],
                        max(e["end"] for e in inserts),
                        completes[-1]["start"]))

print(f"instrumented_v1_rounds_with_select+dequeue = {rounds_with_both}")
print(f"peek_selected_before_consume_and_published_after_consume = {interleaved}")
print(f"  of which peek published after recv fully completed = {strong}")
for d in details[:12]:
    print(f"  case={d[0]} peek_select={d[1]} recv_dequeue={d[2]} "
          f"peek_last_insert_end={d[3]} recv_complete={d[4]}")
