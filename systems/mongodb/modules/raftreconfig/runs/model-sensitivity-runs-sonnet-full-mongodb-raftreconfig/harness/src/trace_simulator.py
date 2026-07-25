#!/usr/bin/env python3
"""
trace_simulator.py — MongoDB Raft Reconfig protocol trace generator.

Implements the TLA+ base spec state machine and emits NDJSON traces for
Trace.tla validation.  Four scenarios cover all instrumented event types.

Node IDs: "n1", "n2", "n3"  — TLC will derive Server = TraceServer from these.
"""

import json
import os
import time

# ─────────────────────────────────────────────────────────────
# Constants matching Trace.cfg / base.tla
# ─────────────────────────────────────────────────────────────
UNINITIALIZED = -1   # kUninitializedTerm

# Role strings emitted (mapped by Trace.tla ToRole)
FOLLOWER  = "SECONDARY"
CANDIDATE = "CANDIDATE"
LEADER    = "PRIMARY"

# Config state strings emitted (mapped by Trace.tla ToConfigState)
STEADY           = "kConfigSteady"
RECONFIGURING    = "kConfigReconfiguring"
POST_SWAP        = "PostSwap"             # synthetic; between swap and barrier
HB_RECONFIGURING = "kConfigHBReconfiguring"

# Message types
M_REQUEST_VOTE       = "RequestVote"
M_REQUEST_VOTE_REPLY = "RequestVoteReply"
M_APPEND_ENTRIES     = "AppendEntries"


# ─────────────────────────────────────────────────────────────
# State per node
# ─────────────────────────────────────────────────────────────
class NodeState:
    def __init__(self, nid, all_nodes):
        self.nid = nid
        self.currentTerm = 0
        self.role = FOLLOWER
        self.votedFor = None          # None = Nil
        self.log = []                 # list of {"term": t, "index": i}
        self.commitIndex = 0
        self.configVersion = 1
        self.configTerm = 0           # 0 = initial (not UNINITIALIZED)
        self.config = set(all_nodes)
        self.configState = STEADY
        self.lastCommittedInPrevConfig = 0
        self.inMemVoteTerm = 0
        self.durableVoteTerm = 0
        self.autoReconfigPending = False
        self.pendingHBConfig = None   # None = Nil

    def config_vat(self):
        return {"version": self.configVersion, "term": self.configTerm}

    def __repr__(self):
        return (f"Node({self.nid} term={self.currentTerm} role={self.role} "
                f"log={len(self.log)} ci={self.commitIndex})")


# ─────────────────────────────────────────────────────────────
# Message pool (list of dicts; we remove on consume)
# ─────────────────────────────────────────────────────────────
messages = []   # reset at start of each scenario

def msg_add(m):
    messages.append(m)

def msg_remove(m):
    messages.remove(m)

def msg_find(pred):
    """Find first message matching pred; None if not found."""
    for m in messages:
        if pred(m):
            return m
    return None


# ─────────────────────────────────────────────────────────────
# ConfigVAT comparison (Family 1)
# ─────────────────────────────────────────────────────────────
def config_less(a, b):
    """True iff a < b per ConfigLess in base.tla."""
    if a["term"] == UNINITIALIZED or b["term"] == UNINITIALIZED:
        return a["version"] < b["version"]
    if a["term"] != b["term"]:
        return a["term"] < b["term"]
    return a["version"] < b["version"]

def config_leq(a, b):
    return a == b or config_less(a, b)


# ─────────────────────────────────────────────────────────────
# Log helpers
# ─────────────────────────────────────────────────────────────
def last_term(log):
    return log[-1]["term"] if log else 0

def log_up_to_date(lterm, lindex, node):
    """True iff (lterm, lindex) ≥ node's log (Raft log freshness check)."""
    my_last = last_term(node.log)
    my_len  = len(node.log)
    return (lterm > my_last
            or (lterm == my_last and lindex >= my_len))


# ─────────────────────────────────────────────────────────────
# Quorum: all majority subsets of a config set
# ─────────────────────────────────────────────────────────────
def quorum(config):
    from itertools import combinations
    cfg = list(config)
    n = len(cfg)
    thresh = n // 2 + 1
    for size in range(thresh, n + 1):
        for subset in combinations(cfg, size):
            yield set(subset)


# ─────────────────────────────────────────────────────────────
# Trace emission
# ─────────────────────────────────────────────────────────────
_trace_file = None

def open_trace(path):
    global _trace_file
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    _trace_file = open(path, "w")

def close_trace():
    global _trace_file
    if _trace_file:
        _trace_file.close()
        _trace_file = None

def emit(obj):
    """Write one NDJSON line; inject tag and real timestamp."""
    obj["tag"] = "trace"
    obj["ts"]  = time.monotonic_ns()
    _trace_file.write(json.dumps(obj) + "\n")
    _trace_file.flush()


# ─────────────────────────────────────────────────────────────
# TLA+ actions: mutate state AND emit trace
# ─────────────────────────────────────────────────────────────

def action_timeout(n):
    """Timeout(n): follower/candidate increments term, self-votes."""
    assert n.role in (FOLLOWER, CANDIDATE), \
        f"Timeout requires Follower/Candidate, got {n.role} for {n.nid}"
    n.currentTerm += 1
    n.role = CANDIDATE
    n.votedFor = n.nid
    # spec: both inMemVote and durableVote updated atomically in Timeout
    n.inMemVoteTerm  = n.currentTerm
    n.durableVoteTerm = n.currentTerm
    emit({
        "event": "Timeout",
        "node":  n.nid,
        "post":  {"currentTerm": n.currentTerm, "role": n.role},
    })


def action_request_votes(candidate, all_nodes_by_id):
    """RequestVotes(candidate): enqueue M_RequestVote messages."""
    assert candidate.role == CANDIDATE
    for voter_id in candidate.config:
        if voter_id == candidate.nid:
            continue
        msg_add({
            "mtype":         M_REQUEST_VOTE,
            "mterm":         candidate.currentTerm,
            "mfrom":         candidate.nid,
            "mto":           voter_id,
            "mconfigVAT":    candidate.config_vat(),
            "mlastLogTerm":  last_term(candidate.log),
            "mlastLogIndex": len(candidate.log),
        })
    emit({
        "event": "RequestVotes",
        "node":  candidate.nid,
        "post":  {"currentTerm": candidate.currentTerm, "role": candidate.role},
    })


def action_handle_request_vote(voter, candidate_id, msg_term, all_nodes_by_id):
    """HandleRequestVote(voter, m): process vote request; emit event.

    Implements base.tla HandleRequestVote exactly:
    - canGrant = configOK ∧ termOK ∧ logOK ∧ votedFor-check
    - currentTerm updated to max(currentTerm, req.mterm)
    - role → Follower iff req.mterm > OLD currentTerm
    - inMemVote updated only when canGrant
    Returns True iff vote was granted.
    """
    m = msg_find(lambda x: (x["mtype"] == M_REQUEST_VOTE
                             and x["mto"] == voter.nid
                             and x["mfrom"] == candidate_id
                             and x["mterm"] == msg_term))
    assert m is not None, \
        f"No M_RequestVote from {candidate_id} to {voter.nid} at term {msg_term}"

    old_term  = voter.currentTerm
    voter_vat = voter.config_vat()

    # Raft guards per base.tla
    config_ok = config_leq(voter_vat, m["mconfigVAT"])
    term_ok   = m["mterm"] >= old_term
    log_ok    = log_up_to_date(m["mlastLogTerm"], m["mlastLogIndex"], voter)
    can_grant = (config_ok and term_ok and log_ok
                 and (voter.votedFor is None or voter.votedFor == candidate_id))

    new_term = m["mterm"] if m["mterm"] > old_term else old_term

    # Mutate state
    voter.currentTerm = new_term
    if m["mterm"] > old_term:      # role → Follower on higher term (uses OLD term)
        voter.role = FOLLOWER
    if can_grant:
        voter.votedFor    = candidate_id
        voter.inMemVoteTerm = new_term

    # Replace request with reply
    msg_remove(m)
    msg_add({
        "mtype":    M_REQUEST_VOTE_REPLY,
        "mterm":    new_term,
        "mfrom":    voter.nid,
        "mto":      candidate_id,
        "mgranted": can_grant,
    })

    emit({
        "event":   "HandleRequestVote",
        "node":    voter.nid,
        "from":    candidate_id,
        "msgTerm": msg_term,
        "post": {
            "currentTerm":   voter.currentTerm,
            "role":          voter.role,
            "inMemVoteTerm": voter.inMemVoteTerm,
        },
    })
    return can_grant


def action_persist_vote(n):
    """PersistVote(n): flush in-memory vote to durable storage.

    Precondition: inMemVoteTerm ≠ durableVoteTerm.
    Only fires after HandleRequestVote grants a vote (HandleRV updates inMem,
    not durable; Timeout updates both atomically so no PersistVote after Timeout).
    """
    assert n.inMemVoteTerm != n.durableVoteTerm, \
        (f"PersistVote({n.nid}): inMem={n.inMemVoteTerm} already == durable={n.durableVoteTerm}; "
         "PersistVote only fires after HandleRequestVote grants a vote")
    n.durableVoteTerm = n.inMemVoteTerm
    emit({
        "event": "PersistVote",
        "node":  n.nid,
        "post":  {"durableVoteTerm": n.durableVoteTerm},
    })


def action_become_leader(n, all_nodes_by_id):
    """BecomeLeader(n): candidate wins when a quorum of votes received."""
    assert n.role == CANDIDATE

    granted = set()
    granted.add(n.nid)   # self-vote always granted via Timeout
    for m in messages:
        if (m["mtype"] == M_REQUEST_VOTE_REPLY
                and m["mto"] == n.nid
                and m["mterm"] == n.currentTerm
                and m["mgranted"]):
            granted.add(m["mfrom"])

    found = any(q.issubset(granted) for q in quorum(n.config))
    assert found, f"BecomeLeader({n.nid}): no quorum; granted={granted}"

    n.role = LEADER
    n.autoReconfigPending = True
    emit({
        "event": "BecomeLeader",
        "node":  n.nid,
        "post":  {
            "currentTerm":         n.currentTerm,
            "role":                n.role,
            "autoReconfigPending": n.autoReconfigPending,
        },
    })


def action_append_entry(n):
    """AppendEntry(n): leader appends a new log entry."""
    assert n.role == LEADER
    idx = len(n.log) + 1
    n.log.append({"term": n.currentTerm, "index": idx})
    emit({
        "event": "AppendEntry",
        "node":  n.nid,
        "post":  {"logLen": len(n.log)},
    })


def action_advance_commit_index(leader, target_ci, all_nodes_by_id):
    """AdvanceCommitIndex(n): advance leader's commitIndex to target_ci.

    Requires a quorum Q in config where all members have ≥ target_ci entries
    with matching log[target_ci-1].
    """
    assert leader.role == LEADER, f"AdvanceCI: {leader.nid} is not LEADER"
    assert target_ci > leader.commitIndex, \
        f"AdvanceCI: target {target_ci} <= current {leader.commitIndex}"
    assert target_ci <= len(leader.log), \
        f"AdvanceCI: target {target_ci} > log length {len(leader.log)}"
    assert leader.log[target_ci - 1]["term"] == leader.currentTerm, \
        (f"AdvanceCI: log[{target_ci}].term={leader.log[target_ci-1]['term']} "
         f"!= currentTerm={leader.currentTerm}")

    for q in quorum(leader.config):
        ok = True
        for nid in q:
            node = all_nodes_by_id[nid]
            if len(node.log) < target_ci:
                ok = False; break
            if node.log[target_ci - 1] != leader.log[target_ci - 1]:
                ok = False; break
        if ok:
            leader.commitIndex = target_ci
            emit({
                "event": "AdvanceCommitIndex",
                "node":  leader.nid,
                "post":  {"commitIndex": leader.commitIndex},
            })
            return

    raise AssertionError(
        f"AdvanceCommitIndex: no quorum for CI={target_ci} "
        f"in config={leader.config}; "
        f"logs={[(n, len(all_nodes_by_id[n].log)) for n in leader.config]}")


def action_auto_reconfig(n):
    """AutoReconfig(n): step-up auto-reconfig bumps configTerm to election term."""
    assert n.role == LEADER
    assert n.autoReconfigPending
    assert n.configState == STEADY
    assert n.configTerm != n.currentTerm, \
        f"AutoReconfig: configTerm={n.configTerm} already == currentTerm={n.currentTerm}"
    n.configVersion += 1
    n.configTerm = n.currentTerm
    n.autoReconfigPending = False
    emit({
        "event": "AutoReconfig",
        "node":  n.nid,
        "post":  {
            "configVersion":       n.configVersion,
            "configTerm":          n.configTerm,
            "configState":         n.configState,
            "autoReconfigPending": n.autoReconfigPending,
        },
    })


def action_auto_reconfig_preempted(n):
    """AutoReconfigPreempted(n): concurrent reconfig blocks auto-reconfig."""
    assert n.role == LEADER
    assert n.autoReconfigPending
    assert n.configState != STEADY
    n.autoReconfigPending = False
    emit({
        "event": "AutoReconfigPreempted",
        "node":  n.nid,
        "post":  {
            "autoReconfigPending": n.autoReconfigPending,
            "configState":         n.configState,
        },
    })


def action_force_reconfig(n, new_cfg, new_version):
    """ForceReconfig(n, newCfg, newVer): sets configTerm = UNINITIALIZED (-1)."""
    assert n.configState == STEADY
    assert new_version > n.configVersion, \
        f"ForceReconfig: newVer={new_version} must > current={n.configVersion}"
    assert len(new_cfg) >= 1
    n.config        = set(new_cfg)
    n.configVersion = new_version
    n.configTerm    = UNINITIALIZED   # -1 = kUninitializedTerm
    n.configState   = STEADY
    n.lastCommittedInPrevConfig = 0
    emit({
        "event":            "ForceReconfig",
        "node":             n.nid,
        "newConfigVersion": new_version,
        "post": {
            "configVersion":             n.configVersion,
            "configTerm":                n.configTerm,
            "configState":               n.configState,
            "lastCommittedInPrevConfig": n.lastCommittedInPrevConfig,
        },
    })


def action_safe_reconfig_start(n, new_cfg):
    """SafeReconfigStart(n, newCfg): transitions to Reconfiguring."""
    assert n.role == LEADER
    assert n.configState == STEADY
    assert n.currentTerm >= 1
    assert len(new_cfg) >= 1
    assert set(new_cfg) != n.config, \
        f"SafeReconfigStart: newCfg={new_cfg} must differ from current={n.config}"
    n.configState = RECONFIGURING
    emit({
        "event": "SafeReconfigStart",
        "node":  n.nid,
        "post":  {"configState": n.configState},
    })


def action_safe_reconfig_swap(n, new_cfg):
    """SafeReconfigSwap(n, newCfg): installs new config, transitions to PostSwap.

    This is the synthetic post-state emitted BEFORE the barrier is captured.
    The implementation has no kConfigPostSwap state; the harness emits it
    immediately after _setCurrentRSConfig returns.
    """
    assert n.configState == RECONFIGURING
    assert n.role == LEADER
    assert len(new_cfg) >= 1
    n.config        = set(new_cfg)
    n.configVersion += 1
    n.configTerm    = n.currentTerm
    n.configState   = POST_SWAP
    emit({
        "event": "SafeReconfigSwap",
        "node":  n.nid,
        "post":  {
            "configVersion": n.configVersion,
            "configTerm":    n.configTerm,
            "configState":   n.configState,
        },
    })


def action_safe_reconfig_capture_barrier(n):
    """SafeReconfigCaptureBarrier(n): captures lastCommittedInPrevConfig."""
    assert n.configState == POST_SWAP
    assert n.role == LEADER
    n.lastCommittedInPrevConfig = n.commitIndex
    n.configState = STEADY
    emit({
        "event": "SafeReconfigCaptureBarrier",
        "node":  n.nid,
        "post":  {
            "configState":               n.configState,
            "lastCommittedInPrevConfig": n.lastCommittedInPrevConfig,
        },
    })


def action_hb_reconfig_schedule(n, new_cfg, new_version, new_term):
    """HBReconfigSchedule(n, newCfg, v, t): transitions to HBReconfiguring.

    Triggered when a heartbeat from a node with higher configVAT is received.
    ConfigLess(n.configVAT, {new_version, new_term}) must hold.

    Emits schedVer/schedTerm/schedCfg so Trace.tla can directly instantiate the
    quantifier \\E newCfg, v, t instead of exploring all ~288 combinations.
    """
    assert n.configState == STEADY, \
        f"HBReconfigSchedule: {n.nid} configState={n.configState}, must be STEADY"
    assert config_less(n.config_vat(), {"version": new_version, "term": new_term}), \
        (f"HBReconfigSchedule: n.configVAT={n.config_vat()} not < "
         f"{{version:{new_version}, term:{new_term}}}")
    n.pendingHBConfig = {"cfg": set(new_cfg), "ver": new_version, "trm": new_term}
    n.configState = HB_RECONFIGURING
    emit({
        "event":     "HBReconfigSchedule",
        "node":      n.nid,
        "schedVer":  new_version,
        "schedTerm": new_term,
        "schedCfg":  sorted(list(new_cfg)),   # JSON array; Trace.tla converts to set
        "post":      {"configState": n.configState},
    })


def action_hb_reconfig_finish(n):
    """HBReconfigFinish(n): installs heartbeat reconfig, returns to Steady."""
    assert n.configState == HB_RECONFIGURING
    assert n.pendingHBConfig is not None
    hb = n.pendingHBConfig
    n.config        = set(hb["cfg"])
    n.configVersion = hb["ver"]
    n.configTerm    = hb["trm"]
    n.configState   = STEADY
    n.pendingHBConfig = None
    emit({
        "event": "HBReconfigFinish",
        "node":  n.nid,
        "post":  {
            "configVersion": n.configVersion,
            "configTerm":    n.configTerm,
            "configState":   n.configState,
        },
    })


# ─────────────────────────────────────────────────────────────
# Silent actions (not traced but needed for spec consistency)
# ─────────────────────────────────────────────────────────────

def silent_send_append_entries(leader, follower):
    """Leader sends full log to follower (silent in trace)."""
    msg_add({
        "mtype":      M_APPEND_ENTRIES,
        "mfrom":      leader.nid,
        "mto":        follower.nid,
        "mterm":      leader.currentTerm,
        "mentries":   list(leader.log),   # full log snapshot
        "mcommit":    leader.commitIndex,
        "mconfigVAT": leader.config_vat(),
    })


def silent_handle_append_entries(follower, leader):
    """Follower applies append entries from leader (silent in trace)."""
    m = msg_find(lambda x: (x["mtype"] == M_APPEND_ENTRIES
                             and x["mto"] == follower.nid
                             and x["mfrom"] == leader.nid))
    if m and m["mterm"] >= follower.currentTerm:
        follower.currentTerm = m["mterm"]
        follower.role        = FOLLOWER
        follower.log         = list(m["mentries"])
        follower.commitIndex = min(m["mcommit"], len(m["mentries"]))
    if m:
        msg_remove(m)


# ─────────────────────────────────────────────────────────────
# Helper: 3-node election where all_ids[0] wins
# ─────────────────────────────────────────────────────────────
def run_election(all_ids):
    """Standard 3-node election.  Returns dict {nid: NodeState}.
    Emits: Timeout, RequestVotes, HandleRV(n2), PersistVote(n2),
           HandleRV(n3), PersistVote(n3), BecomeLeader.
    """
    global messages
    messages = []
    nodes = {nid: NodeState(nid, all_ids) for nid in all_ids}
    n1, n2, n3 = nodes[all_ids[0]], nodes[all_ids[1]], nodes[all_ids[2]]

    action_timeout(n1)                               # term → 1, CANDIDATE
    action_request_votes(n1, nodes)
    action_handle_request_vote(n2, n1.nid, 1, nodes) # n2 grants, inMemVote updated
    action_persist_vote(n2)                           # durable catches up
    action_handle_request_vote(n3, n1.nid, 1, nodes) # n3 grants
    action_persist_vote(n3)
    action_become_leader(n1, nodes)                   # n1 = LEADER

    return nodes


# ─────────────────────────────────────────────────────────────
# Scenario 1 — election_and_auto_reconfig  (~24 events)
# Covers: Timeout, RequestVotes, HandleRV (grant+deny), PersistVote,
#         BecomeLeader, AppendEntry, AdvanceCommitIndex, AutoReconfig
# ─────────────────────────────────────────────────────────────
def scenario_election_and_auto_reconfig(traces_dir):
    path = os.path.join(traces_dir, "election_and_auto_reconfig.ndjson")
    open_trace(path)

    all_ids = ["n1", "n2", "n3"]
    nodes = run_election(all_ids)     # events 1–7
    n1, n2, n3 = nodes["n1"], nodes["n2"], nodes["n3"]

    # Append 5 entries, replicate, commit (events 8–12, 13)
    for _ in range(5):
        action_append_entry(n1)       # events 8–12

    for follower in (n2, n3):
        silent_send_append_entries(n1, follower)
        silent_handle_append_entries(follower, n1)

    action_advance_commit_index(n1, 5, nodes)   # event 13

    action_auto_reconfig(n1)                    # event 14
    # n1.configVersion=2, configTerm=1, autoReconfigPending=False

    # 5 more appends, replicate, commit (events 15–19, 20)
    for _ in range(5):
        action_append_entry(n1)       # events 15–19

    for follower in (n2, n3):
        silent_send_append_entries(n1, follower)
        silent_handle_append_entries(follower, n1)

    action_advance_commit_index(n1, 10, nodes)  # event 20
    # n1.commitIndex=10, n2.log=10, n3.log=10

    # Second election: n2 times out at term 2
    # n1 is still LEADER (term 1), n2 was FOLLOWER (term 1)
    action_timeout(n2)                          # event 21  (n2 → term=2, CANDIDATE)
    action_request_votes(n2, nodes)             # event 22  (sends to n1 and n3)

    # n1 handles n2's vote request:
    #   n1.configVAT={2,1}, n2.configVAT={1,0} → config_leq({2,1},{1,0})=FALSE → canGrant=FALSE
    #   n1 steps down (term 2 > 1), inMemVoteTerm unchanged
    action_handle_request_vote(n1, "n2", 2, nodes)   # event 23  (deny; n1 → SECONDARY/term=2)

    # n3 handles n2's vote request:
    #   n3.configVAT={1,0}, n2.configVAT={1,0} → config_ok=TRUE
    #   votedFor[n3]="n1" ≠ "n2" → canGrant=FALSE
    #   n3 steps down (term 2 > 1), inMemVoteTerm unchanged
    action_handle_request_vote(n3, "n2", 2, nodes)   # event 24  (deny)

    close_trace()
    print(f"  election_and_auto_reconfig.ndjson: 24 events")


# ─────────────────────────────────────────────────────────────
# Scenario 2 — safe_reconfig  (~25 events)
# Covers: all Scenario 1 types plus SafeReconfigStart,
#         SafeReconfigSwap, SafeReconfigCaptureBarrier
# ─────────────────────────────────────────────────────────────
def scenario_safe_reconfig(traces_dir):
    path = os.path.join(traces_dir, "safe_reconfig.ndjson")
    open_trace(path)

    all_ids = ["n1", "n2", "n3"]
    nodes = run_election(all_ids)     # events 1–7
    n1, n2, n3 = nodes["n1"], nodes["n2"], nodes["n3"]

    action_auto_reconfig(n1)          # event 8  (configVAT → {2,1})

    # Append 3 entries, replicate, commit (events 9–11, 12)
    for _ in range(3):
        action_append_entry(n1)       # events 9–11

    for follower in (n2, n3):
        silent_send_append_entries(n1, follower)
        silent_handle_append_entries(follower, n1)

    action_advance_commit_index(n1, 3, nodes)   # event 12

    # Safe reconfig: shrink config to {n1, n2} (events 13–15)
    new_cfg = {"n1", "n2"}
    action_safe_reconfig_start(n1, new_cfg)         # event 13
    action_safe_reconfig_swap(n1, new_cfg)           # event 14  (configVAT → {3,1}, PostSwap)
    action_safe_reconfig_capture_barrier(n1)         # event 15  (lastCommittedInPrevConfig=3, Steady)
    # n1.config={n1,n2}, CI=3

    # Append 4 entries under 2-node config, replicate to n2 only
    for _ in range(4):
        action_append_entry(n1)       # events 16–19

    silent_send_append_entries(n1, n2)
    silent_handle_append_entries(n2, n1)
    # n1.log=7, n2.log=7; Q={n1,n2} both need ≥ target

    action_advance_commit_index(n1, 5, nodes)   # event 20  (CI=5; Q={n1,n2})
    action_advance_commit_index(n1, 7, nodes)   # event 21  (CI=7)

    # Append 2 more, replicate, advance commit twice more
    for _ in range(2):
        action_append_entry(n1)       # events 22–23

    silent_send_append_entries(n1, n2)
    silent_handle_append_entries(n2, n1)

    action_advance_commit_index(n1, 8, nodes)   # event 24
    action_advance_commit_index(n1, 9, nodes)   # event 25

    close_trace()
    print(f"  safe_reconfig.ndjson: 25 events")


# ─────────────────────────────────────────────────────────────
# Scenario 3 — force_reconfig  (~27 events)
# Covers: ForceReconfig (configTerm → UNINITIALIZED)
# ─────────────────────────────────────────────────────────────
def scenario_force_reconfig(traces_dir):
    path = os.path.join(traces_dir, "force_reconfig.ndjson")
    open_trace(path)

    all_ids = ["n1", "n2", "n3"]
    nodes = run_election(all_ids)     # events 1–7
    n1, n2, n3 = nodes["n1"], nodes["n2"], nodes["n3"]

    action_auto_reconfig(n1)          # event 8

    # Append 5 entries, replicate, commit (events 9–13, 14)
    for _ in range(5):
        action_append_entry(n1)       # events 9–13

    for follower in (n2, n3):
        silent_send_append_entries(n1, follower)
        silent_handle_append_entries(follower, n1)

    action_advance_commit_index(n1, 5, nodes)   # event 14

    # 3 more appends, replicate, commit (events 15–17, 18)
    for _ in range(3):
        action_append_entry(n1)       # events 15–17

    for follower in (n2, n3):
        silent_send_append_entries(n1, follower)
        silent_handle_append_entries(follower, n1)

    action_advance_commit_index(n1, 8, nodes)   # event 18

    # Force reconfig: remove n3, configTerm → UNINITIALIZED (event 19)
    force_ver = n1.configVersion + 3  # small increment to stay within MaxConfigVersion=20
    action_force_reconfig(n1, ["n1", "n2"], force_ver)   # event 19

    # 5 appends under force-reconfig config; n2 still receives (in n1's new config)
    for _ in range(5):
        action_append_entry(n1)       # events 20–24

    silent_send_append_entries(n1, n2)   # n3 not in n1.config
    silent_handle_append_entries(n2, n1)

    action_advance_commit_index(n1, 11, nodes)  # event 25  (CI: 8→11; Q={n1,n2})

    # 2 more appends (events 26–27)
    for _ in range(2):
        action_append_entry(n1)       # events 26–27

    close_trace()
    print(f"  force_reconfig.ndjson: 27 events")


# ─────────────────────────────────────────────────────────────
# Scenario 4 — hb_reconfig  (~26 events)
# Covers: HBReconfigSchedule, HBReconfigFinish
# ─────────────────────────────────────────────────────────────
def scenario_hb_reconfig(traces_dir):
    path = os.path.join(traces_dir, "hb_reconfig.ndjson")
    open_trace(path)

    all_ids = ["n1", "n2", "n3"]
    nodes = run_election(all_ids)     # events 1–7
    n1, n2, n3 = nodes["n1"], nodes["n2"], nodes["n3"]

    action_auto_reconfig(n1)          # event 8  (n1.configVAT = {2,1})

    # Append 5 entries, replicate, commit (events 9–13, 14)
    for _ in range(5):
        action_append_entry(n1)       # events 9–13

    for follower in (n2, n3):
        silent_send_append_entries(n1, follower)
        silent_handle_append_entries(follower, n1)

    action_advance_commit_index(n1, 5, nodes)   # event 14

    # Safe reconfig: shrink to {n1, n2} (events 15–17)
    # This gives n1.configVAT = {3,1} while n2, n3 still have {1,0}
    new_cfg_12 = {"n1", "n2"}
    action_safe_reconfig_start(n1, new_cfg_12)        # event 15
    action_safe_reconfig_swap(n1, new_cfg_12)          # event 16  (n1.configVAT → {3,1})
    action_safe_reconfig_capture_barrier(n1)           # event 17  (barrier=5, Steady)

    # HB reconfig on n2: receives heartbeat with n1's configVAT {3,1} (events 18–19)
    # n2.configVAT={1,0} < {3,1} → schedule
    action_hb_reconfig_schedule(n2, ["n1", "n2"], 3, 1)   # event 18
    action_hb_reconfig_finish(n2)                          # event 19
    # n2.config={n1,n2}, configVAT={3,1}

    # HB reconfig on n3: also sees n1's config (events 20–21)
    # n3.configVAT={1,0} < {3,1} → schedule
    action_hb_reconfig_schedule(n3, ["n1", "n2"], 3, 1)   # event 20
    action_hb_reconfig_finish(n3)                          # event 21
    # n3 updates its view (n3 is not in new config, but receives the heartbeat)

    # Append 2 entries only, replicate to n2, commit (fewer states for TLC)
    for _ in range(2):
        action_append_entry(n1)       # events 22–23

    silent_send_append_entries(n1, n2)
    silent_handle_append_entries(n2, n1)
    # n1.log=7, n2.log=7; Q={n1,n2}

    action_advance_commit_index(n1, 6, nodes)   # event 24  (CI=6; Q={n1,n2}, both have 7)
    action_advance_commit_index(n1, 7, nodes)   # event 25  (CI=7)

    # Two final appends without commit (keep event count ≥20 but log small)
    for _ in range(2):
        action_append_entry(n1)       # events 26–27

    close_trace()
    print(f"  hb_reconfig.ndjson: 27 events")


# ─────────────────────────────────────────────────────────────
# Scenario 5 — auto_reconfig_preempted  (~24 events)
# Covers: AutoReconfigPreempted — a concurrent SafeReconfig blocks
#         the step-up auto-reconfig before it fires.
# ─────────────────────────────────────────────────────────────
def scenario_auto_reconfig_preempted(traces_dir):
    path = os.path.join(traces_dir, "auto_reconfig_preempted.ndjson")
    open_trace(path)

    all_ids = ["n1", "n2", "n3"]
    nodes = run_election(all_ids)     # events 1–7 (autoReconfigPending=True for n1)
    n1, n2, n3 = nodes["n1"], nodes["n2"], nodes["n3"]
    # n1: autoReconfigPending=True, configState=Steady, configTerm=0

    # Append 3 entries + commit before the reconfig race (events 8–10, 11)
    for _ in range(3):
        action_append_entry(n1)       # events 8–10

    for follower in (n2, n3):
        silent_send_append_entries(n1, follower)
        silent_handle_append_entries(follower, n1)

    action_advance_commit_index(n1, 3, nodes)   # event 11

    # SafeReconfigStart: configState → Reconfiguring (event 12)
    # autoReconfigPending is still True; configState ≠ Steady now
    new_cfg = {"n1", "n2"}
    action_safe_reconfig_start(n1, new_cfg)         # event 12

    # AutoReconfigPreempted: concurrent reconfig (Reconfiguring) blocks auto-reconfig (event 13)
    action_auto_reconfig_preempted(n1)              # event 13
    # n1.autoReconfigPending = False, configState = Reconfiguring

    # Complete the safe reconfig (events 14–15)
    action_safe_reconfig_swap(n1, new_cfg)           # event 14 (configVAT={2,1}, PostSwap)
    action_safe_reconfig_capture_barrier(n1)         # event 15 (lastCI=3, Steady)
    # n1.configState=Steady, configTerm=1 (set by swap), autoReconfigPending=False

    # Append + replicate + commit under new 2-node config (events 16–21)
    for _ in range(5):
        action_append_entry(n1)       # events 16–20

    silent_send_append_entries(n1, n2)
    silent_handle_append_entries(n2, n1)

    action_advance_commit_index(n1, 5, nodes)   # event 21  (Q={n1,n2})
    action_advance_commit_index(n1, 8, nodes)   # event 22  (CI=8)

    # Two final appends (events 23–24)
    for _ in range(2):
        action_append_entry(n1)       # events 23–24

    close_trace()
    print(f"  auto_reconfig_preempted.ndjson: 24 events")


# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────
def main():
    script_dir  = os.path.dirname(os.path.abspath(__file__))
    traces_dir  = os.path.normpath(os.path.join(script_dir, "..", "..", "traces"))
    os.makedirs(traces_dir, exist_ok=True)

    print("Generating traces...")
    scenario_election_and_auto_reconfig(traces_dir)
    scenario_safe_reconfig(traces_dir)
    scenario_force_reconfig(traces_dir)
    scenario_hb_reconfig(traces_dir)
    scenario_auto_reconfig_preempted(traces_dir)

    # Report event counts and verify JSON validity
    print("\nTrace summary:")
    for fname in sorted(os.listdir(traces_dir)):
        if not fname.endswith(".ndjson"):
            continue
        fpath = os.path.join(traces_dir, fname)
        events = []
        with open(fpath) as f:
            for i, line in enumerate(f, 1):
                try:
                    obj = json.loads(line)
                    events.append(obj.get("event", "?"))
                except json.JSONDecodeError as e:
                    print(f"  ERROR line {i} in {fname}: {e}")
        print(f"  {fname}: {len(events)} events")
        by_type = {}
        for e in events:
            by_type[e] = by_type.get(e, 0) + 1
        for etype, cnt in sorted(by_type.items()):
            print(f"    {etype}: {cnt}")


if __name__ == "__main__":
    main()
