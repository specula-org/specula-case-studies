#!/usr/bin/env python3
"""Generate the payload FINE variants spec/PaySrc_F.tla and spec/PayRcv_F.tla
from the payload seed's structured action declarations.

Source of truth: inputs/seeds/payload/spec/generate.py (read-only), loaded by
scripts/pay_seed.py. Every seed action body (guards, updates, lets) is emitted
verbatim under
    LET st == paySrc_f[si][ln][a]   (PaySrc, process CJ(si), launch ln, attempt a)
    LET st == payRcv_f[si][a]       (PayRcv, process SJ, site si's round-a result)
(one seed transaction record per result transaction Tx(si, ln, a); a = round)
so seed field references `st.X` and EXCEPT paths keep their meaning. Wire
actions (the seed's one-slot channels pullPC/reply/replyNonce/confirmWire/
cancelWire, the by-reference message contents index/consumerResult/
consumerNonce/futureStarted, and the shutdownSourcesPending oracle) are
re-encoded as messages by the hand-written overrides below.

Usage: python3 scripts/pay_gen.py
"""
import os, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import pay_seed  # noqa: E402

SPEC = Path(os.environ.get("MIX_SPEC") or (ROOT / "spec"))
D = "download_service.py:"

# ----------------------------------------------------------------- partition
RCV = {"DownloadObjectStart", "ConsumerReceiveData", "ConsumerLaunchPipeline",
       "ConsumerConsumeReturn", "ConsumerConsumeException", "ConsumerReceiveEOF",
       "ConsumerDownloadCompleted", "ConsumerDownloadCompletedException",
       "ConsumerSendConfirm", "ConsumerReceiveError", "ConsumerReceiveProducerError",
       "DownloadRequestWorkerStart", "SourceDownloadRegister", "SourceDownloadEnter",
       "SourceFailureNotify", "ShutdownSourceDownloads", "ConsumerSourceAbortBegin",
       "ConsumerSourceAbortNotified", "ConsumerSourceAbortExit", "SourceDownloadUnregister"}
# Environment stand-ins of the seed replaced by real neighbors (not emitted).
DROPPED = {
    "LoseConfirmation": "ENV_NET: replaced by the Net group (Net_L loses any message kind)",
    "WaitForResultTransfers": "ENV_CALLER: trainer barrier belongs to the TaskCJ/trainer component",
    "GetTransferWaiter": "late second waiter API: no second observer exists in the slice",
}
# Seed fault classes -> Faults toggles of the payload component.
FAULTS = {"produce": "payProduce", "consumer": "payConsumer", "delete": "payDelete",
          "submit": "paySubmit", "executorStop": "paySubmit", "compute": "payCompute",
          "callback": "payCallback", "sourceFailure": "sourceFailure"}
# seed field -> group. Fields not listed for a group are absent from its record.
RCV_FIELDS = ["consumer", "index", "consumerNonce", "consumerResult", "abandoned",
              "sourceStarted", "sourceEntered", "sourceRegistered", "sourceEnded",
              "sourceFailures", "sourceSignal", "abortNotified", "consumerReturn"]
WIRE_FIELDS = {"pullPC", "reply", "replyNonce", "futureStarted", "confirmWire",
               "cancelWire", "shutdownSourcesPending", "caller"}

# ------------------------------------------------------------------- helpers


def split_top(text, sep=","):
    out, depth, cur, i = [], 0, "", 0
    while i < len(text):
        if text.startswith("<<", i):
            depth += 1; cur += "<<"; i += 2; continue
        if text.startswith(">>", i):
            depth -= 1; cur += ">>"; i += 2; continue
        ch = text[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if depth == 0 and text.startswith(sep, i):
            out.append(cur); cur = ""; i += len(sep); continue
        cur += ch; i += 1
    out.append(cur)
    return [x.strip() for x in out if x.strip()]


def parse_init(init_text):
    body = init_text[init_text.index("st = [") + len("st = ["):]
    body = body[:body.rindex("]")]
    body = "\n".join(l.split("\\*")[0] for l in body.splitlines())
    fields = {}
    for item in split_top(" ".join(body.split())):
        k, v = item.split("|->", 1)
        fields[k.strip()] = v.strip()
    return fields


def fix(expr):
    """Seed helpers that read `st` take it as an explicit argument here."""
    expr = expr.replace("FirstProgressEvent(", "FirstProgressEvent(st, ")
    return expr


DOM = [("Confirmers \\cup Cancellers", "PayConfirmers \\cup PayCancellers"),
       ("SUBSET Refs", "SUBSET PayRefs"), ("Pairs", "PayPairs"), ("Settlers", "PaySettlers"),
       ("Actors", "PayActors"), ("Finalizers", "PayFinalizers"), ("Receivers", "PayReceivers"),
       ("Refs", "PayRefs")]


def portdom(d):
    """Seed binder domain -> Ports-level name (mix-root binders cannot see module-local sets)."""
    for a, b in DOM:
        if d == a or d.startswith(a + " "):
            return d.replace(a, b, 1)
    return d


def lets_block(lets, extra=()):
    defs = list(extra) + ([fix(l) for l in lets.split("\n")] if lets else [])
    return defs


def emit(name, sig, source, trigger, defs, guards, priv_update, other, fault=None, note=None):
    L = [f"\\* {source}: {trigger}"]
    if note:
        L.append(f"\\* REMIX: {note}")
    L.append(f"{sig} ==")
    L.append("    LET " + defs[0])
    for d in defs[1:]:
        L.append("        " + d.replace("\n", "\n            "))
    L.append("    IN")
    if fault:
        L.append(f'    /\\ "{fault}" \\in Faults')
    for g in guards:
        L.append(f"    /\\ {g}")
    if priv_update:
        L.append(f"    /\\ {priv_update}")
    for o in other:
        L.append(f"    /\\ {o}")
    return "\n".join(L) + "\n"


def exc(updates, indent="          "):
    return (",\n" + indent).join(f"!.{k} = {v}" for k, v in updates)


# ------------------------------------------------------------------- PaySrc

SRC_HEADER = r'''------------------------------ MODULE PaySrc_F ------------------------------
\* GENERATED by scripts/pay_gen.py from the payload seed
\* (inputs/seeds/payload/spec/generate.py, source pin c411a201). Do not edit.
\* Group PaySrc, FINE variant. Process: CJ(si), one DownloadService
\* transaction per (launch ln, attempt a = FedAvg round): result tx Tx(si, ln, a)
\* with ref Ref(si, ln, a) (slice: one ref, one receiver SJ per transaction).
\* Seed groups PAY_SRC_SERVE + PAY_SRC_SETTLE (they share the per-ref progress
\* lock where MC-2 lives). Every seed action keeps its name, guards, updates
\* and file:line anchor; `st` is this (si, ln, a) transaction record.
\* Re-homing (see notes/pay-impl.md):
\*  - Seed Init (pre-registered tx, first waiter attached) -> Register, driven
\*    by pTaskCJ[si][ln].submission of round a (one registration per round).
\*  - pullPC/reply/replyNonce/index -> PAYLOAD_PULL [ref, n] / PAYLOAD_REPLY
\*    [status, value, nonce] messages; hpc[p] is the CJ handler PC, hreq[p] the
\*    admitted request key, hidx[p] its request state (n - 1).
\*  - confirmWire/consumerResult/consumerNonce -> RECEIVER_CONFIRM [ref, nonce,
\*    status] captured into fconf[t] at admission; cancelWire -> RECEIVER_CANCEL.
\*  - Shutdown (DownloadService.shutdown) is applied once RunCJ's run-finally
\*    ShutdownDownloadService step set pRunCJ[si][ln].dsDown (client_runner.py:814-821;
\*    that step carries timing T1, PortsJob!CJTeardownTimingOK); shutdownSourcesPending
\*    (SJ-side oracle) is deleted.
\*  - DownloadService.shutdown covers every transaction of the process: while it
\*    is pending (DSShutdownPending), only the per-transaction Shutdown steps run.
\*  - AdvanceTime is this transaction's CJ clock, bounded by TimeLimit ("txTimeout" fault
\*    enables timeouts, drain expiry and receipt expiry).
\*  - LoseConfirmation -> Net group; WaitForResultTransfers, GetTransferWaiter
\*    dropped (no trainer barrier / second observer in the slice).
\*  - New: ServeUnknownRef (INVALID_REQUEST for a ref this process never had,
\*    download_service.py:1704-1706), used after a CJ relaunch.
EXTENDS Ports
VARIABLE paySrc_f

\* Slice profile (inputs/vertical-slice/checks/interfaces/payload/PayloadRefinement.tla).
Refs == {"ref-1"}
RefOrder == <<"ref-1">>
Receivers == {"SJ"}
ChunkCount == 1
AcquireTimeout == 0
IdleTimeout == 0
TxTimeout == 5
DrainTimeout == 2
ReceiptTTL == 4
MinReceivers == 1
FirstRegisteredRef == "ref-1"
FinishedRefsTTL == 9
TimeLimit == IF "txTimeout" \in Faults THEN TxTimeout + 1 ELSE 0
'''

SRC_TAIL_DEFS = r'''
ProgressRank(st, p) == CHOOSE i \in 1..Len(st.progressOrder[p[1]]) : st.progressOrder[p[1]][i] = p[2]
FirstProgressEvent(st, es) == CHOOSE e \in es : \A q \in es : ProgressRank(st, e.pair) <= ProgressRank(st, q.pair)

\* ---- wire encoding shared with PaySrc_C / PayRcv_F / PayRcv_C
ServeNonce(si, ln, a) == <<"nonce", si, ln, a>>
MyRef(si, ln, a) == pPaySrc[si][ln].tx[a].registered.ref
TxUpd(si, ln, a, r) == SrcTxSet(pPaySrc, si, ln, a, r)
RcWire(rc) == CASE rc = "data" -> "DATA" [] rc = "eof" -> "EOF" [] rc = "error" -> "ERROR"
                [] rc = "exception" -> "PROCESS_EXCEPTION" [] OTHER -> "INVALID_REQUEST"
ReplyMsg(si, mk, status, value, nonce) ==
    Msg("PAYLOAD_REPLY", CJ(si), M(mk).from, M(mk).id,
        [status |-> status, value |-> value, nonce |-> nonce])
ForMe(si, ln, a, mk, kind) ==
    /\ InInbox(mk, CJ(si), kind) /\ mk \notin paySrc_f[si][ln][a].handled
    /\ M(mk).body.ref = MyRef(si, ln, a)
\* RunCJ declared the run-finally DownloadService.shutdown (pRunCJ.dsDown) but this
\* group's table teardown has not been applied yet: the real call is ONE step, so
\* only Shutdown may run in between (split-step atomicity across groups). The call
\* covers every registered transaction of the process. shutdown() first takes the
\* table lock (Shutdown requires ~tableLocked): while a monitor pass holds it, the
\* other threads keep running (otherwise the lock holder could never release it).
DSShutdownPending(si, ln) == Flag(pRunCJ[si][ln], "dsDown")
    /\ (\E b \in Attempts : paySrc_f[si][ln][b].reg /\ ~paySrc_f[si][ln][b].shutdown)
    /\ (\A b \in Attempts : ~paySrc_f[si][ln][b].tableLocked)
\* The receiver identity of a requester process (slice: the SJ is "SJ").
RcvOf(proc) == "SJ"
'''


def src_init_record(seed_init):
    keep = {k: v for k, v in seed_init.items() if k not in RCV_FIELDS and k not in WIRE_FIELDS}
    keep.update({
        "reg": "FALSE",
        # shutdown() put this live transaction into its synchronous inline
        # settlement; the call returns (port shut) only when that settlement's
        # SyncTerminationMarkerWrite finishes (download_service.py:1502-1505)
        "shutWait": "FALSE",
        "handled": "{}",
        "hpc": '[p \\in Pairs |-> "idle"]',
        "hreq": "[p \\in Pairs |-> None]",
        "hidx": "[p \\in Pairs |-> 0]",
        "fconf": "[t \\in Finalizers |-> [status |-> \"none\", nonce |-> None]]",
    })
    return keep


SRC_PORT = {
    "ReleaseSourceReference": ("pPaySrc' = TxUpd(si, ln, a, [pPaySrc[si][ln].tx[a] EXCEPT !.released = TRUE])",
                               "port released (Cacheable.release dropped the infrastructure reference)"),
    "RecordOutcome": ("pPaySrc' = TxUpd(si, ln, a, [pPaySrc[si][ln].tx[a] EXCEPT !.outcome = st.verdicts[t].status])",
                      "port outcome = recorded receipt status"),
    "Shutdown": ("pPaySrc' = IF st.live THEN pPaySrc ELSE TxUpd(si, ln, a, [pPaySrc[si][ln].tx[a] EXCEPT !.shut = TRUE])",
                 "return side of the call (port shut, RunCJ waits for PaySrcShutDone): at once for a transaction "
                 "that was no longer live; for a live one only after shutdown()'s synchronous inline settlement "
                 "(transaction_done(DELETED) + _sync_termination_marker, download_service.py:1502-1505) finished"),
    "SyncTerminationMarkerWrite": ("pPaySrc' = IF t = Inline /\\ st.shutWait THEN TxUpd(si, ln, a, [pPaySrc[si][ln].tx[a] EXCEPT !.shut = TRUE]) ELSE pPaySrc",
                 "the inline settlement started by shutdown() finished: shutdown() returns for this transaction (port shut)"),
}


def src_generic(a):
    name = a["name"]
    params = [(n, d) for n, d in a["params"] if n != "arg"]
    guards = [fix(g) for g in a["guards"] if g != "arg = CallbackArgs(t)"]
    updates = list(a["updates"])
    lets = a["lets"]
    note = None
    # rename CJ handler PC and request state
    ren = lambda s: s.replace("st.pullPC[", "st.hpc[").replace("st.index[p]", "st.hidx[p]")
    guards = [ren(g) for g in guards]
    updates = [(k.replace("pullPC[", "hpc["), ren(v)) for k, v in updates]
    if name == "RefFinalizeReceiverCommit":
        lets = lets.replace("st.consumerResult[p]", "st.fconf[t].status")
        lets = lets.replace("st.consumerNonce[p]", "st.fconf[t].nonce = ServeNonce(si, ln, a)")
        note = "CONFIRM content (status, nonce) captured at admission replaces the SJ fields read by reference"
    if name == "Shutdown":
        updates = [(k, v) for k, v in updates if k != "shutdownSourcesPending"] + [("shutWait", "st.live")]
        guards = guards + ['Flag(pRunCJ[si][ln], "dsDown")']
        note = ("triggered by RunCJ's run-finally ShutdownDownloadService step (pRunCJ.dsDown, gated by "
                "timing T1); SJ-side oracle removed")
    if name == "SyncTerminationMarkerWrite":
        updates = list(updates) + [("shutWait", "IF t = Inline THEN FALSE ELSE @")]
    if name == "AdvanceTime":
        guards = ["st.now < TimeLimit"]
        note = "CJ-local clock bounded by TimeLimit"
    for k, v in updates:
        base = k.split("[")[0].split(".")[0]
        assert base not in RCV_FIELDS and base not in WIRE_FIELDS, (name, k)
    blob = " ".join(guards + [v for _, v in updates] + [lets])
    for f in RCV_FIELDS + sorted(WIRE_FIELDS):
        assert not re.search(r"st\." + f + r"\b", blob), (name, f)
    fault = FAULTS.get(a["fault"]) if a["fault"] not in (None, "shutdown", "time") else None
    sig = name + "(" + ", ".join(["si", "ln", "a"] + [n for n, _ in params]) + ")"
    defs = lets_block(lets, ["st == paySrc_f[si][ln][a]"])
    gl = ["st.reg /\\ CJAlive(si, ln)"] + ([] if name == "Shutdown" else ["~DSShutdownPending(si, ln)"]) + [f"({g})" for g in guards]
    upd = f"paySrc_f' = [paySrc_f EXCEPT ![si][ln][a] = [st EXCEPT\n          {exc(updates)}]]"
    other = []
    if name in SRC_PORT:
        other.append(SRC_PORT[name][0]); other.append("UNCHANGED net")
        note = (note + "; " if note else "") + SRC_PORT[name][1]
    else:
        other.append("UNCHANGED <<pPaySrc, net>>")
    text = emit(name, sig, a["source"], a["trigger"], defs, gl, upd, other, fault, note)
    dom = [(n, d.replace("st.", "paySrc_f[si][ln][a].")) for n, d in params]
    return text, dom


def rekey_src(text):
    """Seed-record override text written for one tx per launch -> one tx per (si, ln, a)."""
    text = re.sub(r"^(\w+)\(si, ln", r"\1(si, ln, a", text, flags=re.M)
    text = re.sub(r"paySrc_f\[si\]\[ln\](?!\[a\])", "paySrc_f[si][ln][a]", text)
    text = text.replace("[paySrc_f EXCEPT ![si][ln]", "[paySrc_f EXCEPT ![si][ln][a]")
    text = text.replace("pPaySrc[si][ln].registered", "pPaySrc[si][ln].tx[a].registered")
    for h in ("ServeNonce", "MyRef"):
        text = text.replace(h + "(si, ln)", h + "(si, ln, a)")
    text = text.replace("ForMe(si, ln, mk", "ForMe(si, ln, a, mk")
    return text


def src_overrides():
    O = {}
    O["Register"] = (r'''\* download_service.py:270-298,1315-1401; via_downloader.py:513-650: new_transaction +
\* add_object under the table/outcome locks before the payload is exposed; the
\* result sender attaches the first waiter (seed Init state).
\* REMIX: replaces the seed's pre-registered Init; driven by the round-a submission
\* (one transaction Tx(si, ln, a) per round).
Register(si, ln) ==
    LET st == paySrc_f[si][ln]
        sub == pTaskCJ[si][ln].submission
    IN
    /\ sub /= None /\ sub.assignment.attempt = a
    /\ pPaySrc[si][ln].registered = None /\ CJAlive(si, ln) /\ ~st.reg
    /\ pPaySrc' = TxUpd(si, ln, a, [pPaySrc[si][ln].tx[a] EXCEPT !.registered =
          [ref |-> Ref(si, ln, a), source |-> CJ(si), launch |-> ln, value |-> sub.value]])
    /\ paySrc_f' = [paySrc_f EXCEPT ![si][ln].reg = TRUE]
    /\ UNCHANGED net
''', [])
    O["HandleDownloadBegin"] = (r'''\* download_service.py:1681-1699,822-833: admit a pull while holding the table and operation locks
\* REMIX: consumes PAYLOAD_PULL mk (seed: pullPC[p] = "sent" /\ futureStarted[p]); request state n-1.
HandleDownloadBegin(si, ln, p, mk) ==
    LET st == paySrc_f[si][ln] IN
    /\ st.reg /\ CJAlive(si, ln) /\ ~DSShutdownPending(si, ln)
    /\ ForMe(si, ln, mk, "PAYLOAD_PULL") /\ p[2] = RcvOf(M(mk).from)
    /\ st.hpc[p] \in {"idle", "done"}
    /\ st.live /\ ~st.closed /\ ~st.tableLocked
    /\ paySrc_f' = [paySrc_f EXCEPT ![si][ln] = [st EXCEPT
          !.handled = @ \cup {mk}, !.ops = @ \cup {Pull(p)}, !.hpc[p] = "markTx",
          !.hreq[p] = mk, !.hidx[p] = M(mk).body.n - 1]]
    /\ UNCHANGED <<pPaySrc, net>>
''', [("p", "Pairs"), ("mk", "DOMAIN net")])
    O["HandleDownloadMissing"] = (r'''\* download_service.py:1681-1707: after ref retirement, return retained finished status or missing-ref error; includes a late first acquisition
\* REMIX: consumes PAYLOAD_PULL mk and sends PAYLOAD_REPLY; "missing" = ReturnCode.INVALID_REQUEST.
HandleDownloadMissing(si, ln, p, mk) ==
    LET st == paySrc_f[si][ln]
        rc == IF ~st.shutdown /\ st.tombstoneAt >= 0 /\ st.now - st.tombstoneAt <= FinishedRefsTTL
              THEN (IF st.status[p] = "success" THEN "eof" ELSE "error") ELSE "missing"
    IN
    /\ st.reg /\ CJAlive(si, ln) /\ ~DSShutdownPending(si, ln)
    /\ ForMe(si, ln, mk, "PAYLOAD_PULL") /\ p[2] = RcvOf(M(mk).from)
    /\ (~st.live \/ st.closed)
    /\ (~st.tableLocked)
    /\ paySrc_f' = [paySrc_f EXCEPT ![si][ln].handled = @ \cup {mk}]
    /\ net' = Send(net, ReplyMsg(si, mk, RcWire(rc), None, None))
    /\ UNCHANGED pPaySrc
''', [("p", "Pairs"), ("mk", "DOMAIN net")])
    O["ServeUnknownRef"] = (r'''\* download_service.py:1696-1706: no ref (and no finished-ref tombstone) for rid -> INVALID_REQUEST
\* REMIX: new; a pull for a ref of an earlier launch of this site reaches the current CJ process.
\* Not per transaction (the ref matches no registered attempt): the reply key is the only record.
ServeUnknownRef(si, ln, mk) ==
    /\ CJAlive(si, ln) /\ ln = CurLaunch(si) /\ \A l2 \in Launches : l2 /= ln => ~CJAlive(si, l2)
    /\ InInbox(mk, CJ(si), "PAYLOAD_PULL")
    /\ \A b \in Attempts : IF pPaySrc[si][ln].tx[b].registered = None THEN TRUE
                           ELSE M(mk).body.ref /= MyRef(si, ln, b)
    /\ Fresh(net, ReplyMsg(si, mk, "INVALID_REQUEST", None, None))
    /\ net' = Send(net, ReplyMsg(si, mk, "INVALID_REQUEST", None, None))
    /\ UNCHANGED <<pPaySrc, paySrc_f>>
''', [("mk", "DOMAIN net")])
    O["HandleDownloadEndOp"] = (r'''\* download_service.py:1750,1768-1779,835-839: finally leaves the operation gate before the reply becomes receivable
\* REMIX: sends PAYLOAD_REPLY for the admitted request (seed: reply[p] := rc, replyNonce[p] := nonce[p]).
HandleDownloadEndOp(si, ln, p) ==
    LET st == paySrc_f[si][ln] IN
    /\ st.reg /\ CJAlive(si, ln) /\ ~DSShutdownPending(si, ln)
    /\ (st.hpc[p] = "end")
    /\ (st.pub[Pull(p)].pc = "idle")
    /\ paySrc_f' = [paySrc_f EXCEPT ![si][ln] = [st EXCEPT
          !.ops = @ \ {Pull(p)}, !.hpc[p] = "done"]]
    /\ net' = Send(net, ReplyMsg(si, st.hreq[p], RcWire(st.rc[p]),
                 IF st.rc[p] = "data" THEN pPaySrc[si][ln].registered.value ELSE None,
                 IF st.nonce[p] THEN ServeNonce(si, ln) ELSE None))
    /\ UNCHANGED pPaySrc
''', [("p", "Pairs")])
    O["HandleConfirmBegin"] = (r'''\* download_service.py:1782-1799,822-833: admit confirmation, preserving nonce requirement for the later final-status lock
\* REMIX: consumes RECEIVER_CONFIRM mk; its (status, nonce) is captured into fconf (seed read SJ state at commit).
HandleConfirmBegin(si, ln, p, mk) ==
    LET st == paySrc_f[si][ln] IN
    /\ st.reg /\ CJAlive(si, ln) /\ ~DSShutdownPending(si, ln)
    /\ ForMe(si, ln, mk, "RECEIVER_CONFIRM") /\ p[2] = RcvOf(M(mk).from)
    /\ (st.fpc[Confirm(p)] = "idle")
    /\ (st.live) /\ (~st.closed) /\ (~st.tableLocked)
    /\ paySrc_f' = [paySrc_f EXCEPT ![si][ln] = [st EXCEPT
          !.handled = @ \cup {mk}, !.ops = @ \cup {Confirm(p)}, !.ftodo[Confirm(p)] = {p},
          !.fpc[Confirm(p)] = "select",
          !.fconf[Confirm(p)] = [status |-> M(mk).body.status, nonce |-> M(mk).body.nonce]]]
    /\ UNCHANGED <<pPaySrc, net>>
''', [("p", "Pairs"), ("mk", "DOMAIN net")])
    O["HandleConfirmLate"] = (r'''\* download_service.py:1783-1793: drop confirmation after retirement/closed gate
\* REMIX: consumes RECEIVER_CONFIRM mk.
HandleConfirmLate(si, ln, p, mk) ==
    LET st == paySrc_f[si][ln] IN
    /\ st.reg /\ CJAlive(si, ln) /\ ~DSShutdownPending(si, ln)
    /\ ForMe(si, ln, mk, "RECEIVER_CONFIRM") /\ p[2] = RcvOf(M(mk).from)
    /\ (~st.live \/ st.closed)
    /\ (~st.tableLocked)
    /\ paySrc_f' = [paySrc_f EXCEPT ![si][ln].handled = @ \cup {mk}]
    /\ UNCHANGED <<pPaySrc, net>>
''', [("p", "Pairs"), ("mk", "DOMAIN net")])
    O["HandleCancelBegin"] = (r'''\* download_service.py:1814-1827,822-833: admit cancellation before testing transaction-level acquisition
\* REMIX: consumes RECEIVER_CANCEL mk from receiver rv (wire keyed by (ref, requester), no nonce).
HandleCancelBegin(si, ln, rv, mk) ==
    LET st == paySrc_f[si][ln] IN
    /\ st.reg /\ CJAlive(si, ln) /\ ~DSShutdownPending(si, ln)
    /\ ForMe(si, ln, mk, "RECEIVER_CANCEL") /\ rv = RcvOf(M(mk).from)
    /\ (st.fpc[Cancel(rv)] = "idle")
    /\ (st.live) /\ (~st.closed) /\ (~st.tableLocked)
    /\ paySrc_f' = [paySrc_f EXCEPT ![si][ln] = [st EXCEPT
          !.handled = @ \cup {mk}, !.ops = @ \cup {Cancel(rv)}, !.fpc[Cancel(rv)] = "acquired"]]
    /\ UNCHANGED <<pPaySrc, net>>
''', [("rv", "Receivers"), ("mk", "DOMAIN net")])
    O["HandleCancelLate"] = (r'''\* download_service.py:1816-1822: drop cancellation after retirement/closed gate
\* REMIX: consumes RECEIVER_CANCEL mk.
HandleCancelLate(si, ln, rv, mk) ==
    LET st == paySrc_f[si][ln] IN
    /\ st.reg /\ CJAlive(si, ln) /\ ~DSShutdownPending(si, ln)
    /\ ForMe(si, ln, mk, "RECEIVER_CANCEL") /\ rv = RcvOf(M(mk).from)
    /\ (~st.live \/ st.closed)
    /\ (~st.tableLocked)
    /\ paySrc_f' = [paySrc_f EXCEPT ![si][ln].handled = @ \cup {mk}]
    /\ UNCHANGED <<pPaySrc, net>>
''', [("rv", "Receivers"), ("mk", "DOMAIN net")])
    return O


def gen_src(rec, seed_init, ns):
    hdr = ns["parts"][0]
    a = hdr.index("OneRefOrder ==")
    b = hdr.index("\\* Single state record")
    helpers = hdr[a:b]
    helpers = "\n".join(l for l in helpers.splitlines()
                        if not l.startswith("TwoRefOrder") and not l.startswith("DefaultRefOrder"))
    rec_fields = src_init_record(seed_init)
    O = src_overrides()
    out = [SRC_HEADER, helpers, SRC_TAIL_DEFS]
    out.append("SrcInit0 == [" + ",\n             ".join(f"{k} |-> {v}" for k, v in rec_fields.items()) + "]")
    out.append("InitValue == [si \\in Sites |-> [ln \\in Launches |-> [a \\in Attempts |-> SrcInit0]]]")
    out.append("Init == paySrc_f = InitValue\n")
    nxt = []
    order = ["Register"] + [x["name"] for x in rec] + ["ServeUnknownRef"]
    byname = {x["name"]: x for x in rec}
    count = 0
    for name in order:
        if name in RCV or name in DROPPED:
            continue
        pertx = name != "ServeUnknownRef"
        if name in O:
            text, dom = O[name]
            if pertx:
                text = rekey_src(text)
        else:
            text, dom = src_generic(byname[name])
        out.append(text)
        count += 1
        flat = [(n, d) for n, d in dom if "paySrc_f" not in d]
        dep = [(n, d) for n, d in dom if "paySrc_f" in d]
        txb = ["a \\in Attempts"] if pertx else []
        binders = ", ".join(["si \\in Sites", "ln \\in Launches"] + txb + [f"{n} \\in {portdom(d)}" for n, d in flat])
        inner = "".join(f"\\E {n} \\in {d} : " for n, d in dep)
        args = ", ".join(["si", "ln"] + (["a"] if pertx else []) + [n for n, _ in dom])
        nxt.append(f"    \\/ \\E {binders} : {inner}{name}({args})")
    out.append(SRC_ABS)
    out.append("Next ==\n" + "\n".join(nxt))
    out.append("=" * 77)
    (SPEC / "PaySrc_F.tla").write_text("\n".join(out) + "\n")
    return count


SRC_ABS = r'''
ASSUME /\ PayPairs = Pairs /\ PayRefs = Refs /\ PayReceivers = Receivers /\ PayActors = Actors
       /\ PaySettlers = Settlers /\ PayFinalizers = Finalizers
       /\ PayConfirmers = Confirmers /\ PayCancellers = Cancellers
\* ---- abstraction to PaySrc_C's private state (interaction-preservation map)
P0 == <<"ref-1", "SJ">>
AbsOne(st) == [live |-> st.reg /\ st.live, rcv |-> st.status[P0], cause |-> st.cause,
               shut |-> st.shutdown,
               adm |-> {st.hreq[q] : q \in {q2 \in Pairs : st.hpc[q2] \notin {"idle", "done"}}}]
AbsC == [si \in Sites |-> [ln \in Launches |-> [a \in Attempts |-> AbsOne(paySrc_f[si][ln][a])]]]
AbsCInit == [si \in Sites |-> [ln \in Launches |-> [a \in Attempts |-> AbsOne(SrcInit0)]]]

\* ---- seed diagnostic properties, per transaction (group-internal; S19 canaries)
PayCompletedProgressHasReceiverSuccess == \A si \in Sites, ln \in Launches, a \in Attempts, p \in Pairs :
    paySrc_f[si][ln][a].observedTerminal[p] = "completed" => paySrc_f[si][ln][a].status[p] = "success"
PaySingleSettlementEffects == \A si \in Sites, ln \in Launches, a \in Attempts :
    LET st == paySrc_f[si][ln][a] IN
    /\ st.doneCalls <= 1 /\ st.outcomeCbCalls <= 1
    /\ \A r \in Refs : st.objectDoneCalls[r] <= 1 /\ st.releaseAttempts[r] <= 1
PayNoSettlementEffectsAfterReceipt == \A si \in Sites, ln \in Launches, a \in Attempts : ~paySrc_f[si][ln][a].effectsAfterReceipt
PaySingleReceipt == \A si \in Sites, ln \in Launches, a \in Attempts :
    paySrc_f[si][ln][a].receiptWrites <= 1 /\ (paySrc_f[si][ln][a].receiptWrites = 1 => ~paySrc_f[si][ln][a].owner)
PayClosedAfterRetirement == \A si \in Sites, ln \in Launches, a \in Attempts : paySrc_f[si][ln][a].closed => ~paySrc_f[si][ln][a].live
PayFinalStatusStructure == \A si \in Sites, ln \in Launches, a \in Attempts, p \in Pairs :
    LET st == paySrc_f[si][ln][a] IN
    /\ (st.status[p] # "none" => ~st.pending[p])
    /\ (st.pending[p] = (st.provisional[p] # "none"))
PayOutcomeAggregation == \A si \in Sites, ln \in Launches, a \in Attempts :
    LET st == paySrc_f[si][ln][a] IN
    \A v \in {st.receipt, st.waiterOutcome} \cup {st.verdicts[t] : t \in Settlers} :
       /\ (v.status = "completed" => v.refsPresent /\ AllSucceeded(v.matrix))
       /\ (v.quorum => v.refsPresent /\ Cardinality(CommonSuccess(v.matrix)) >= MinReceivers)
PaySrcSafety == PaySingleReceipt /\ PayClosedAfterRetirement /\ PayFinalStatusStructure
                /\ PayOutcomeAggregation
'''

# ------------------------------------------------------------------- PayRcv

RCV_HEADER = r'''------------------------------ MODULE PayRcv_F ------------------------------
\* GENERATED by scripts/pay_gen.py from the payload seed
\* (inputs/seeds/payload/spec/generate.py, source pin c411a201). Do not edit.
\* Group PayRcv, FINE variant. Process: SJ; one receiver attempt per (site si,
\* round a): the round-a result envelope's single ref Ref(si, l, a). Seed group PAY_RCV: download_object /
\* _download_object consumer pipeline and the SJ-side owned-source signal
\* registry (_register/_unregister_source_download, _handle_source_failure,
\* SJ DownloadService.shutdown). `st` is the receiver record of (si, a).
\* Re-homing (see notes/pay-impl.md):
\*  - Receivers no longer start spontaneously: SourceDownloadRegister is driven
\*    by the decoded RESULT_ENVELOPE (pCommSJ.envelopes[si], round a =
\*    its assignment attempt).
\*  - pullPC (SJ part) -> rpc[p] in idle/sent/queued/done; PULL sent at
\*    DownloadObjectStart / DownloadRequestWorkerStart; the one-slot reply ->
\*    the PAYLOAD_REPLY of the current request (reqN), consumed via handled.
\*  - confirmWire / cancelWire -> RECEIVER_CONFIRM / RECEIVER_CANCEL messages.
\*  - ShutdownSourceDownloads is the SJ's own DownloadService.shutdown after
\*    END_RUN (server_runner.py:235-237), driven by pWfSJ.dsShutdown.
\*  - New: PullTimeout (fault "pullTimeout": per-request timeouts exhaust
\*    max_retries) and PullSourceGone (the source CJ is gone: transport error),
\*    both the non-OK rc branch at download_service.py:2240-2270.
\*  - Abort check first (download_service.py:2236-2238): a reply or request
\*    failure is processed only if the source signal is not yet triggered;
\*    otherwise ConsumerSourceAbortBegin(where = "reply") is the only path
\*    (guard st.sourceSignal[p] = "none" added to the seed's Consumer*Receive*
\*    actions and to PullRetry/PullTimeout/PullSourceGone).
\*  - Decode outcome (cell.py:116-135): at download_object return a local
\*    DownloadCancelled is non-fatal (SERVICE_UNAVAILABLE); any other failed
\*    decode of the streamed SUBMIT_UPDATE calls os._exit(1) -> port fatal.
EXTENDS Ports
VARIABLE payRcv_f

Refs == {"ref-1"}
Receivers == {"SJ"}
Pairs == Refs \X Receivers
ChunkCount == 1
FinalStatuses == {"none", "success", "failed"}
EmptyMatrix == [p \in Pairs |-> "none"]

Desc(si, a) == pPayRcv[si].rx[a].want
RxUpd(si, a, r) == RcvRxSet(pPayRcv, si, a, r)
\* Ids carry the request state n, the try k (a TIMEOUT retry resends the same
\* state under a fresh key, download_service.py:2243-2262) and, for CONFIRM /
\* CANCEL, the generation of the descriptor (receiver attempt); the source
\* still matches CONFIRM/CANCEL by ref only (body), as the wire does.
PullMsg(si, a, n, k) == Msg("PAYLOAD_PULL", SJ, Desc(si, a).source, <<"pull", Desc(si, a).ref, n, k>>,
                      [ref |-> Desc(si, a).ref, n |-> n, try |-> k])
ConfirmMsg(si, a, nonce, status) == Msg("RECEIVER_CONFIRM", SJ, Desc(si, a).source,
                      <<"confirm", Desc(si, a).ref, Desc(si, a).launch>>,
                      [ref |-> Desc(si, a).ref, nonce |-> nonce, status |-> status])
CancelMsg(si, a) == Msg("RECEIVER_CANCEL", SJ, Desc(si, a).source, <<"cancel", Desc(si, a).ref, Desc(si, a).launch>>,
                      [ref |-> Desc(si, a).ref, status |-> "cancelled"])
\* Bounded retries of one request state (source default max_retries = 3; slice: 1).
MaxPullTry == IF {"pullTimeout", "netLoss"} \cap Faults /= {} THEN 2 ELSE 1
\* The reply to the current request of pair p (one outstanding request per pair).
RKey(si, a, p) == MsgKey("PAYLOAD_REPLY", Desc(si, a).source, SJ,
                      <<"pull", Desc(si, a).ref, payRcv_f[si][a].reqN[p], payRcv_f[si][a].reqK[p]>>)
ReplyIn(si, a, p) == /\ Desc(si, a) /= None /\ payRcv_f[si][a].rpc[p] = "sent"
                     /\ RKey(si, a, p) \in DOMAIN net /\ InInbox(RKey(si, a, p), SJ, "PAYLOAD_REPLY")
                     /\ RKey(si, a, p) \notin payRcv_f[si][a].handled
RBody(si, a, p) == net[RKey(si, a, p)].msg.body
\* What the receiver can observe of its source: real death or a false suspicion.
SrcGone(si, a) == PeerFailureCJ(si, Desc(si, a).launch)
\* WfSJ declared the SJ's DownloadService.shutdown (pWfSJ.dsShutdown) but this group's
\* signal publication has not been applied yet: one real step, so only
\* ShutdownSourceDownloads may run in between (split-step atomicity across groups).
SJShutdownPending == Flag(pWfSJ, "dsShutdown") /\ \E s \in Sites, b \in Attempts : ~payRcv_f[s][b].sjShutdown
'''


def rcv_init_record(seed_init):
    keep = {k: seed_init[k] for k in RCV_FIELDS}
    keep["consumerNonce"] = "[p \\in Pairs |-> None]"
    keep.update({"rpc": '[p \\in Pairs |-> "idle"]', "reqN": "[p \\in Pairs |-> 0]",
                 "reqK": "[p \\in Pairs |-> 0]",
                 "handled": "{}", "data": "None", "sjShutdown": "FALSE"})
    return keep


def rcv_generic(a):
    name = a["name"]
    params = list(a["params"])
    guards = list(a["guards"])
    updates = list(a["updates"])
    for k, v in updates:
        base = k.split("[")[0].split(".")[0]
        assert base in RCV_FIELDS, (name, k)
    blob = " ".join(guards + [v for _, v in updates] + [a["lets"]])
    for f in sorted(WIRE_FIELDS):
        assert not re.search(r"st\." + f + r"\b", blob), (name, f)
    fault = FAULTS.get(a["fault"]) if a["fault"] else None
    sig = name + "(" + ", ".join(["si", "a"] + [n for n, _ in params]) + ")"
    defs = lets_block(a["lets"], ["st == payRcv_f[si][a]"])
    gl = ["SJAlive /\\ ~SJShutdownPending"] + [f"({g})" for g in guards]
    upd = f"payRcv_f' = [payRcv_f EXCEPT ![si][a] = [st EXCEPT\n          {exc(updates)}]]"
    text = emit(name, sig, a["source"], a["trigger"], defs, gl, upd, ["UNCHANGED <<pPayRcv, net>>"], fault)
    return text, params


def rekey_rcv(text):
    """Receiver override text written for one receiver per site -> one per (si, a)."""
    text = re.sub(r"^(\w+)\(si(\W)", r"\1(si, a\2", text, flags=re.M)
    text = re.sub(r"payRcv_f\[si\](?!\[a\])", "payRcv_f[si][a]", text)
    text = text.replace("[payRcv_f EXCEPT ![si]", "[payRcv_f EXCEPT ![si][a]")
    text = text.replace("![si][a][a]", "![si][a]")
    for h in ("Desc(si)", "CancelMsg(si)", "SrcGone(si)"):
        text = text.replace(h, h[:-1] + ", a)")
    for h in ("PullMsg(si, ", "ConfirmMsg(si, ", "RKey(si, ", "ReplyIn(si, ", "RBody(si, "):
        text = text.replace(h, h + "a, ")
    return text


def rcv_overrides():
    O = {}
    O["SourceDownloadRegister"] = (r'''\* download_service.py:_register_source_download:1286-1297: register an actual receiver attempt and atomically consume a cached source failure
\* REMIX: driven by the decoded RESULT_ENVELOPE (FOBS decode calls download_object per ref); port want/status.
SourceDownloadRegister(si, p) ==
    LET st == payRcv_f[si] IN
    /\ SJAlive /\ ~SJShutdownPending /\ pCommSJ.envelopes[si] /= None
    /\ pCommSJ.envelopes[si].assignment.attempt = a /\ pPayRcv[si].rx[a].want = None
    /\ "slowEnvelope" \in Faults \/ ~Flag(pWfSJ, "dsShutdown")   \* timing T3 (PortsPay)
    /\ (p \notin st.sourceStarted)
    /\ (st.consumer[p] = "new")
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.sourceStarted = @ \cup {p},
          !.sourceRegistered = @ \cup {p},
          !.sourceSignal[p] = IF p[1] \in st.sourceFailures THEN "failed" ELSE "none"]]
    /\ pPayRcv' = RxUpd(si, a, [pPayRcv[si].rx[a] EXCEPT
                     !.want = CHOOSE d \in pCommSJ.envelopes[si].refs : TRUE, !.status = "pulling"])
    /\ UNCHANGED net
''', [("p", "Pairs")])
    O["DownloadObjectStart"] = (r'''\* download_service.py:2164-2182,2203-2209: send the initial ordinary pull
\* REMIX: sends PAYLOAD_PULL n = index + 1 (seed: pullPC[p] := "sent", futureStarted[p] := TRUE).
DownloadObjectStart(si, p) ==
    LET st == payRcv_f[si] IN
    /\ SJAlive /\ ~SJShutdownPending /\ Desc(si) /= None
    /\ (st.consumer[p] = "new")
    /\ (p \in st.sourceEntered)
    /\ (p[2] \notin st.abandoned)
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.consumer[p] = "waiting", !.rpc[p] = "sent", !.reqN[p] = st.index[p] + 1, !.reqK[p] = 1]]
    /\ net' = Send(net, PullMsg(si, st.index[p] + 1, 1))
    /\ UNCHANGED pPayRcv
''', [("p", "Pairs")])
    O["ConsumerReceiveData"] = (r'''\* download_service.py:2212-2213,2291-2298: receive DATA and remember cancel capability; one unit consumed next
\* REMIX: consumes the current request's PAYLOAD_REPLY (status DATA); keeps the data value.
ConsumerReceiveData(si, p) ==
    LET st == payRcv_f[si] IN
    /\ SJAlive /\ ~SJShutdownPending
    /\ st.sourceSignal[p] = "none"
    /\ (st.consumer[p] = "waiting")
    /\ ReplyIn(si, p) /\ RBody(si, p).status = "DATA"
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.handled = @ \cup {RKey(si, p)}, !.rpc[p] = "done",
          !.consumer[p] = "data", !.index[p] = @ + 1, !.data = RBody(si, p).value]]
    /\ UNCHANGED <<pPayRcv, net>>
''', [("p", "Pairs")])
    O["ConsumerLaunchPipeline"] = (r'''\* download_service.py:2300-2305: submit next request BEFORE calling consume on the current data
\* REMIX: queues the next PULL (seed: pullPC[p] := "sent", futureStarted[p] := FALSE).
ConsumerLaunchPipeline(si, p) ==
    LET st == payRcv_f[si] IN
    /\ SJAlive /\ ~SJShutdownPending
    /\ (st.consumer[p] = "data")
    /\ (st.rpc[p] = "done")
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.consumer[p] = "consuming", !.rpc[p] = "queued"]]
    /\ UNCHANGED <<pPayRcv, net>>
''', [("p", "Pairs")])
    O["DownloadRequestWorkerStart"] = (r'''\* download_service.py:2166-2182,2300-2305,2312-2313: the submitted pipeline future starts before remote admission; cancel can no longer erase the request
\* REMIX: transmits the queued PAYLOAD_PULL n = index + 1 (seed: futureStarted[p] := TRUE).
DownloadRequestWorkerStart(si, p) ==
    LET st == payRcv_f[si] IN
    /\ SJAlive /\ ~SJShutdownPending /\ Desc(si) /= None
    /\ (st.rpc[p] = "queued")
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.rpc[p] = "sent", !.reqN[p] = st.index[p] + 1, !.reqK[p] = 1]]
    /\ net' = Send(net, PullMsg(si, st.index[p] + 1, 1))
    /\ UNCHANGED pPayRcv
''', [("p", "Pairs")])
    O["ConsumerConsumeException"] = (r'''\* download_service.py:2311-2317: consume raises; cancel an unstarted future, but an admitted request keeps running
\* REMIX: sends RECEIVER_CANCEL (seed: cancelWire); an unstarted queued PULL is erased.
ConsumerConsumeException(si, p) ==
    LET st == payRcv_f[si] IN
    /\ "payConsumer" \in Faults
    /\ SJAlive /\ ~SJShutdownPending /\ Desc(si) /= None
    /\ (st.consumer[p] = "consuming")
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.consumer[p] = "failed", !.consumerResult[p] = "failed", !.abandoned = @ \cup {p[2]},
          !.rpc[p] = IF st.rpc[p] = "queued" THEN "done" ELSE @]]
    /\ net' = Send(net, CancelMsg(si))
    /\ UNCHANGED pPayRcv
''', [("p", "Pairs")])
    O["ConsumerReceiveEOF"] = (r'''\* download_service.py:2260-2274: receive EOF and enter download_completed before sending any confirmation
\* REMIX: consumes the current PAYLOAD_REPLY (status EOF); keeps its nonce value.
ConsumerReceiveEOF(si, p) ==
    LET st == payRcv_f[si] IN
    /\ SJAlive /\ ~SJShutdownPending
    /\ st.sourceSignal[p] = "none"
    /\ (st.consumer[p] = "waiting")
    /\ ReplyIn(si, p) /\ RBody(si, p).status = "EOF"
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.handled = @ \cup {RKey(si, p)}, !.rpc[p] = "done",
          !.consumerNonce[p] = RBody(si, p).nonce, !.consumer[p] = "completing"]]
    /\ UNCHANGED <<pPayRcv, net>>
''', [("p", "Pairs")])
    O["ConsumerDownloadCompleted"] = (r'''\* download_service.py:2273-2283: download_completed returns successfully
\* REMIX: the consumer finalized the data: port status materialized + value.
ConsumerDownloadCompleted(si, p) ==
    LET st == payRcv_f[si] IN
    /\ SJAlive /\ ~SJShutdownPending
    /\ (st.consumer[p] = "completing")
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.consumerResult[p] = "success", !.consumer[p] = "confirmReady"]]
    /\ pPayRcv' = RxUpd(si, a, [pPayRcv[si].rx[a] EXCEPT !.status = "materialized",
                                                            !.materialized = st.data])
    /\ UNCHANGED net
''', [("p", "Pairs")])
    O["ConsumerSendConfirm"] = (r'''\* download_service.py:2083-2105,2279-2283: send receiver truth only if terminal reply requested nonce-bound confirmation
\* REMIX: sends RECEIVER_CONFIRM [ref, nonce, status] by value (seed: confirmWire).
ConsumerSendConfirm(si, p) ==
    LET st == payRcv_f[si] IN
    /\ SJAlive /\ ~SJShutdownPending /\ Desc(si) /= None
    /\ (st.consumer[p] = "confirmReady")
    /\ payRcv_f' = [payRcv_f EXCEPT ![si].consumer[p] = "done"]
    /\ IF st.consumerNonce[p] /= None
       THEN net' = Send(net, ConfirmMsg(si, st.consumerNonce[p], st.consumerResult[p]))
       ELSE UNCHANGED net
    /\ UNCHANGED pPayRcv
''', [("p", "Pairs")])
    O["ConsumerReceiveError"] = (r'''\* download_service.py:2221-2250: ordinary failed request causes cancellation after acquisition
\* REMIX: consumes a PROCESS_EXCEPTION / INVALID_REQUEST reply; RECEIVER_CANCEL iff index > 0.
ConsumerReceiveError(si, p) ==
    LET st == payRcv_f[si] IN
    /\ SJAlive /\ ~SJShutdownPending
    /\ st.sourceSignal[p] = "none"
    /\ (st.consumer[p] = "waiting")
    /\ ReplyIn(si, p) /\ RBody(si, p).status \in {"PROCESS_EXCEPTION", "INVALID_REQUEST"}
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.handled = @ \cup {RKey(si, p)}, !.rpc[p] = "done",
          !.consumer[p] = "failed", !.consumerResult[p] = "failed", !.abandoned = @ \cup {p[2]}]]
    /\ IF st.index[p] > 0 THEN net' = Send(net, CancelMsg(si)) ELSE UNCHANGED net
    /\ UNCHANGED pPayRcv
''', [("p", "Pairs")])
    O["ConsumerReceiveProducerError"] = (r'''\* download_service.py:2260-2265,2285-2289: terminal ERROR carries nonce; prepare FAILED confirmation without download_completed
\* REMIX: consumes the current PAYLOAD_REPLY (status ERROR).
ConsumerReceiveProducerError(si, p) ==
    LET st == payRcv_f[si] IN
    /\ SJAlive /\ ~SJShutdownPending
    /\ st.sourceSignal[p] = "none"
    /\ (st.consumer[p] = "waiting")
    /\ ReplyIn(si, p) /\ RBody(si, p).status = "ERROR"
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.handled = @ \cup {RKey(si, p)}, !.rpc[p] = "done",
          !.consumerNonce[p] = RBody(si, p).nonce, !.consumerResult[p] = "failed",
          !.consumer[p] = "confirmReady"]]
    /\ UNCHANGED <<pPayRcv, net>>
''', [("p", "Pairs")])
    O["PullTimeout"] = (r'''\* download_service.py:2243-2262: rc TIMEOUT with retries left: back off and resend the same state
\* REMIX: new (fault "pullTimeout" or "netLoss"); fresh key per try; a late reply to the old try is dropped.
PullRetry(si, p) ==
    LET st == payRcv_f[si] IN
    /\ {"pullTimeout", "netLoss"} \cap Faults /= {}
    /\ SJAlive /\ ~SJShutdownPending /\ Desc(si) /= None /\ st.sourceSignal[p] = "none"
    /\ st.consumer[p] = "waiting" /\ st.rpc[p] = "sent" /\ RKey(si, p) \notin st.handled
    /\ st.reqK[p] < MaxPullTry
    /\ payRcv_f' = [payRcv_f EXCEPT ![si].reqK[p] = @ + 1]
    /\ net' = Send(net, PullMsg(si, st.reqN[p], st.reqK[p] + 1))
    /\ UNCHANGED pPayRcv

\* download_service.py:2263-2270: TIMEOUT after max_retries -> _send_cancel, download_failed
\* REMIX: new (fault "pullTimeout" or "netLoss"); the remote request may still be admitted and served later.
PullTimeout(si, p) ==
    LET st == payRcv_f[si] IN
    /\ {"pullTimeout", "netLoss"} \cap Faults /= {}
    /\ SJAlive /\ ~SJShutdownPending /\ Desc(si) /= None /\ st.sourceSignal[p] = "none"
    /\ st.consumer[p] = "waiting" /\ st.rpc[p] = "sent" /\ RKey(si, p) \notin st.handled
    /\ st.reqK[p] = MaxPullTry
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.rpc[p] = "done", !.consumer[p] = "failed", !.consumerResult[p] = "failed",
          !.abandoned = @ \cup {p[2]}]]
    /\ IF st.index[p] > 0 THEN net' = Send(net, CancelMsg(si)) ELSE UNCHANGED net
    /\ UNCHANGED pPayRcv
''', [("p", "Pairs")])
    O["PullRetry"] = (O["PullTimeout"][0].split("\n\n")[0] + "\n", [("p", "Pairs")])
    O["PullTimeout"] = (O["PullTimeout"][0].split("\n\n", 1)[1], [("p", "Pairs")])
    O["PullSourceGone"] = (r'''\* download_service.py:2240-2262; cell.py:518-653: the source CJ process is gone, the request returns a non-OK rc
\* REMIX: new; reaction to PeerFailureCJ (real CJ death, or a false suspicion under "transportFail");
\* a non-TIMEOUT rc is not retried.
PullSourceGone(si, p) ==
    LET st == payRcv_f[si] IN
    /\ SJAlive /\ ~SJShutdownPending /\ Desc(si) /= None /\ SrcGone(si) /\ st.sourceSignal[p] = "none"
    /\ st.consumer[p] = "waiting" /\ st.rpc[p] = "sent" /\ RKey(si, p) \notin st.handled
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.rpc[p] = "done", !.consumer[p] = "failed", !.consumerResult[p] = "failed",
          !.abandoned = @ \cup {p[2]}]]
    /\ IF st.index[p] > 0 THEN net' = Send(net, CancelMsg(si)) ELSE UNCHANGED net
    /\ UNCHANGED pPayRcv
''', [("p", "Pairs")])
    O["ShutdownSourceDownloads"] = (r'''\* download_service.py:shutdown:1495-1506: publish typed local cancellation without overwriting earlier failure; clear registry under source failure lock
\* REMIX: the SJ's own DownloadService.shutdown after END_RUN (server_runner.py:235-237, posted by
\* WfSJ as pWfSJ.dsShutdown), one atomic step over every site's receiver; replaces the
\* cross-process shutdownSourcesPending oracle.
ShutdownSourceDownloads ==
    /\ SJAlive /\ Flag(pWfSJ, "dsShutdown")
    /\ \A si \in Sites, a \in Attempts : ~payRcv_f[si][a].sjShutdown
    /\ payRcv_f' = [si \in Sites |-> [a \in Attempts |-> LET st == payRcv_f[si][a] IN [st EXCEPT
          !.sourceSignal = [p \in Pairs |-> IF p \in st.sourceRegistered /\ st.sourceSignal[p] = "none" THEN "cancelled" ELSE st.sourceSignal[p]],
          !.sourceRegistered = {},
          !.sourceFailures = {},
          !.sjShutdown = TRUE]]]
    /\ pPayRcv' = RcvAllDown(pPayRcv)   \* return side of the call: WfSJ's exit waits for PayRcvShutDone
    /\ UNCHANGED net
''', None)
    O["ConsumerSourceAbortBegin"] = (r'''\* download_service.py:download_object:2021-2028; _abort_download:2139-2144: observe the actual saved abort reason and begin consumer notification; preserve admitted pipeline work
\* REMIX: RECEIVER_CANCEL iff canCancel; an arrived current reply is dropped (where = "reply").
ConsumerSourceAbortBegin(si, p, where, canCancel) ==
    LET st == payRcv_f[si]
        okReply == ReplyIn(si, p) /\ RBody(si, p).status \in {"DATA", "EOF", "ERROR"}
    IN
    /\ SJAlive /\ ~SJShutdownPending /\ Desc(si) /= None
    /\ (st.sourceSignal[p] # "none")
    /\ ((where = "initial" /\ st.consumer[p] = "new" /\ p \notin st.sourceEntered) \/ (where = "reply" /\ st.consumer[p] = "waiting") \/ (where = "consume" /\ st.consumer[p] = "consuming"))
    /\ (canCancel = (where # "initial" /\ (st.index[p] > 0 \/ okReply)))
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.consumer[p] = "aborting", !.consumerResult[p] = "failed", !.abandoned = @ \cup {p[2]},
          !.handled = IF where = "reply" /\ ReplyIn(si, p) THEN @ \cup {RKey(si, p)} ELSE @,
          !.rpc[p] = IF where = "consume" /\ st.rpc[p] = "queued" THEN "done" ELSE @]]
    /\ IF canCancel THEN net' = Send(net, CancelMsg(si)) ELSE UNCHANGED net
    /\ UNCHANGED pPayRcv
''', [("p", "Pairs"), ("where", '{"initial","reply","consume"}'), ("canCancel", "BOOLEAN")])
    O["SourceDownloadUnregister"] = (r'''\* download_service.py:_unregister_source_download:1299-1308; download_object:2039-2041; cell.py:116-135: finally removes the same signal; download_object returns or raises into FOBS decode
\* REMIX: port returned/status; a failed decode that is not a local DownloadCancelled kills the SJ (os._exit(1)).
SourceDownloadUnregister(si, p) ==
    LET st == payRcv_f[si]
        ok == st.consumerResult[p] = "success"
    IN
    /\ SJAlive /\ ~SJShutdownPending
    /\ (p \in st.sourceStarted)
    /\ (p \notin st.sourceEnded)
    /\ (st.consumer[p] \in {"done","failed","cancelled"})
    /\ payRcv_f' = [payRcv_f EXCEPT ![si] = [st EXCEPT
          !.sourceRegistered = @ \ {p},
          !.sourceEnded = @ \cup {p}]]
    /\ pPayRcv' = RxUpd(si, a, [pPayRcv[si].rx[a] EXCEPT !.returned = TRUE,
                                  !.status = IF ok THEN "materialized" ELSE "failed",
                                  !.fatal = ~ok /\ st.consumerReturn[p] /= "cancelled"])
    /\ UNCHANGED net
''', [("p", "Pairs")])
    return O


RCV_ABS = r'''
ASSUME PayPairs = Pairs /\ PayRefs = Refs /\ PayReceivers = Receivers
\* ---- abstraction to PayRcv_C's private state (interaction-preservation map)
P0 == <<"ref-1", "SJ">>
PhaseOf(cs) == CASE cs = "new" -> "idle"
                 [] cs \in {"waiting", "data", "consuming"} -> "pulling"
                 [] cs = "completing" -> "eof"
                 [] cs = "confirmReady" -> "confirm"
                 [] cs = "done" -> "done"
                 [] OTHER -> "failed"
AbsOne(st) == [phase |-> PhaseOf(st.consumer[P0]), data |-> st.data,
               nonce |-> st.consumerNonce[P0], result |-> st.consumerResult[P0]]
AbsC == [si \in Sites |-> [a \in Attempts |-> AbsOne(payRcv_f[si][a])]]
AbsCInit == [si \in Sites |-> [a \in Attempts |-> AbsOne(RcvInit0)]]

\* ---- seed diagnostic property (group-internal): a typed local cancellation is
\* only reported after the consumer was notified (Update.tla LocalCancellationNotified).
PayLocalCancellationNotified == \A si \in Sites, a \in Attempts, p \in Pairs :
    payRcv_f[si][a].consumerReturn[p] = "cancelled" => payRcv_f[si][a].abortNotified[p]
'''


def gen_rcv(rec, seed_init):
    O = rcv_overrides()
    out = [RCV_HEADER]
    fields = rcv_init_record(seed_init)
    out.append("RcvInit0 == [" + ",\n             ".join(f"{k} |-> {v}" for k, v in fields.items()) + "]")
    out.append("InitValue == [si \\in Sites |-> [a \\in Attempts |-> RcvInit0]]")
    out.append("Init == payRcv_f = InitValue\n")
    byname = {x["name"]: x for x in rec}
    order = [x["name"] for x in rec if x["name"] in RCV] + ["PullRetry", "PullTimeout", "PullSourceGone"]
    nxt = []
    count = 0
    for name in order:
        if name in O:
            text, dom = O[name]
            if dom is not None:
                text = rekey_rcv(text)
        else:
            text, dom = rcv_generic(byname[name])
        out.append(text)
        count += 1
        if dom is None:
            nxt.append(f"    \\/ {name}")
            continue
        binders = ", ".join(["si \\in Sites", "a \\in Attempts"] + [f"{n} \\in {portdom(d)}" for n, d in dom])
        args = ", ".join(["si", "a"] + [n for n, _ in dom])
        nxt.append(f"    \\/ \\E {binders} : {name}({args})")
    out.append(RCV_ABS)
    out.append("Next ==\n" + "\n".join(nxt))
    out.append("=" * 77)
    (SPEC / "PayRcv_F.tla").write_text("\n".join(out) + "\n")
    return count


def main():
    rec, init_text, ns = pay_seed.load()
    seed_init = parse_init(ns["parts"][0][ns["parts"][0].index("Init =="):])
    n1 = gen_src(rec, seed_init, ns)
    n2 = gen_rcv(rec, seed_init)
    print(f"PaySrc_F: {n1} actions; PayRcv_F: {n2} actions; dropped {sorted(DROPPED)}")


if __name__ == "__main__":
    main()
