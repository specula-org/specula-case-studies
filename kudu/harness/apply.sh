#!/usr/bin/env bash
# Apply TLA+ trace instrumentation to the Kudu consensus source code.
# Usage: cd case-studies/kudu && bash harness/apply.sh
set -euo pipefail

ARTIFACT="artifact/incubator-kudu"
CONSENSUS="$ARTIFACT/src/kudu/consensus"

echo "=== Applying TLA+ trace instrumentation ==="

# 0. Clean any previous instrumentation
cd "$(dirname "$0")/.."
git -C "$ARTIFACT" checkout -- . 2>/dev/null || true

# 1. Copy trace module files
echo "[1/3] Copying trace module..."
cp harness/src/tla_trace.h  "$CONSENSUS/tla_trace.h"
cp harness/src/tla_trace.cc "$CONSENSUS/tla_trace.cc"

# 2. Add tla_trace.cc to CMakeLists.txt
echo "[2/3] Updating CMakeLists.txt..."
if ! grep -q 'tla_trace.cc' "$CONSENSUS/CMakeLists.txt"; then
  sed -i '/^  consensus_peers.cc$/a\  tla_trace.cc' "$CONSENSUS/CMakeLists.txt"
fi

# 3. Instrument source files using Python for reliability
echo "[3/3] Instrumenting source files..."

python3 << 'PYEOF'
import re, sys

def insert_after_line(lines, line_num, code):
    """Insert code after a 1-indexed line number."""
    lines.insert(line_num, code + '\n')
    return lines

def find_line(lines, pattern):
    """Find first line matching pattern, return 0-indexed."""
    for i, line in enumerate(lines):
        if pattern in line:
            return i
    raise ValueError(f"Pattern not found: {pattern}")

def find_line_after(lines, pattern, after_idx=0):
    """Find first line matching pattern after a given index."""
    for i in range(after_idx, len(lines)):
        if pattern in lines[i]:
            return i
    raise ValueError(f"Pattern not found after line {after_idx}: {pattern}")

def read_file(path):
    with open(path, 'r') as f:
        return f.readlines()

def write_file(path, lines):
    with open(path, 'w') as f:
        f.writelines(lines)

CONSENSUS = "artifact/incubator-kudu/src/kudu/consensus"

# ===========================================================================
# raft_consensus.cc
# ===========================================================================
RC = f"{CONSENSUS}/raft_consensus.cc"
lines = read_file(RC)

# Add include
idx = find_line(lines, '#include "kudu/consensus/time_manager.h"')
lines.insert(idx + 1, '#include "kudu/consensus/tla_trace.h"\n')

# Helper: generate full state capture block
def state_capture(varname, role_expr, voted_for_expr):
    return f"""    tla_trace::TraceState {varname};
    {varname}.term = CurrentTermUnlocked();
    {varname}.role = {role_expr};
    {varname}.votedFor = {voted_for_expr};
    {varname}.commitIndex = pending_->GetCommittedIndex();
    OpId {varname}_last = queue_->GetLastOpIdInLog();
    {varname}.lastLogIndex = {varname}_last.index();
    {varname}.lastLogTerm = {varname}_last.term();"""

def weak_state_capture(varname, term_expr, role_expr):
    return f"""    tla_trace::TraceState {varname};
    {varname}.term = {term_expr};
    {varname}.role = {role_expr};
    {varname}.is_weak = true;"""

# --- BecomeCandidate / PreVote ---
# Insert before "RaftConfigPB active_config = cmeta_->ActiveConfig();" inside StartElection
idx = find_line(lines, 'RaftConfigPB active_config = cmeta_->ActiveConfig();')
code = """
    // --- TLA+ trace: BecomeCandidate / PreVote ---
    if (tla_trace::IsEnabled()) {
      tla_trace::TraceState tbc;
      tbc.term = CurrentTermUnlocked();
      tbc.role = "Candidate";
      if (mode != PRE_ELECTION) {
        tbc.votedFor = tla_trace::Nid(peer_uuid());
      } else {
        tbc.votedFor = HasVotedCurrentTermUnlocked()
            ? tla_trace::Nid(GetVotedForCurrentTermUnlocked()) : "";
      }
      tbc.commitIndex = pending_->GetCommittedIndex();
      OpId tbc_last = queue_->GetLastOpIdInLog();
      tbc.lastLogIndex = tbc_last.index();
      tbc.lastLogTerm = tbc_last.term();
      const char* ename = (mode == PRE_ELECTION) ? "PreVote" : "BecomeCandidate";
      tla_trace::TraceEvent(ename)
          .Node(tla_trace::Nid(peer_uuid()))
          .State(tbc)
          .Emit();
    }
"""
lines.insert(idx, code)

# --- Self-vote HandleRequestVoteResponse ---
# Insert after "Inexplicable duplicate self-vote for term" line
idx = find_line(lines, 'Inexplicable duplicate self-vote for term')
# Find the semicolon closing the CHECK statement (next line ending with ;)
while not lines[idx].rstrip().endswith(';'):
    idx += 1
code = """
    // --- TLA+ trace: self-vote HandleRequestVoteResponse ---
    if (tla_trace::IsEnabled()) {
      tla_trace::TraceState tsv;
      tsv.term = CurrentTermUnlocked();
      tsv.role = "Candidate";
      if (mode != PRE_ELECTION) {
        tsv.votedFor = tla_trace::Nid(peer_uuid());
      } else {
        tsv.votedFor = HasVotedCurrentTermUnlocked()
            ? tla_trace::Nid(GetVotedForCurrentTermUnlocked()) : "";
      }
      tsv.commitIndex = pending_->GetCommittedIndex();
      OpId tsv_last = queue_->GetLastOpIdInLog();
      tsv.lastLogIndex = tsv_last.index();
      tsv.lastLogTerm = tsv_last.term();
      tla_trace::TraceEvent("HandleRequestVoteResponse")
          .Node(tla_trace::Nid(peer_uuid()))
          .State(tsv)
          .MsgStr("from", tla_trace::Nid(peer_uuid()))
          .MsgStr("to", tla_trace::Nid(peer_uuid()))
          .MsgBool("voteGranted", true)
          .MsgInt("term", CurrentTermUnlocked())
          .Emit();
    }
"""
lines.insert(idx + 1, code)

# --- Set trace_commit_index_ on election object ---
# Insert trace_ci__ before election.reset and SetTraceCommitIndex after the closing paren
idx = find_line(lines, 'election.reset(new LeaderElection(')
lines.insert(idx, '    auto trace_ci__ = pending_->GetCommittedIndex();\n')
# Find the closing "}))" of the election.reset call, then insert SetTraceCommitIndex after it
idx2 = find_line_after(lines, '}));', idx)
lines.insert(idx2 + 1, '    election->SetTraceCommitIndex(trace_ci__);\n')

# --- BecomeLeader ---
idx = find_line(lines, 'leader_is_ready_ = true;')
code = """
  // --- TLA+ trace: BecomeLeader ---
  if (tla_trace::IsEnabled()) {
    tla_trace::TraceState tbl;
    tbl.term = CurrentTermUnlocked();
    tbl.role = "Leader";
    tbl.votedFor = tla_trace::Nid(peer_uuid());
    tbl.commitIndex = pending_->GetCommittedIndex();
    OpId tbl_last = queue_->GetLastOpIdInLog();
    tbl.lastLogIndex = tbl_last.index();
    tbl.lastLogTerm = tbl_last.term();
    tla_trace::TraceEvent("BecomeLeader")
        .Node(tla_trace::Nid(peer_uuid()))
        .State(tbl)
        .Emit();
  }
"""
lines.insert(idx + 1, code)

# --- StepDown ---
idx = find_line(lines, '"explicit stepdown request"')
code = """  // --- TLA+ trace: StepDown ---
  if (tla_trace::IsEnabled()) {
    tla_trace::TraceState tsd;
    tsd.term = CurrentTermUnlocked();
    tsd.role = "Follower";
    tsd.votedFor = "";
    tsd.commitIndex = pending_->GetCommittedIndex();
    OpId tsd_last = queue_->GetLastOpIdInLog();
    tsd.lastLogIndex = tsd_last.index();
    tsd.lastLogTerm = tsd_last.term();
    tla_trace::TraceEvent("StepDown")
        .Node(tla_trace::Nid(peer_uuid()))
        .State(tsd)
        .Emit();
  }
"""
lines.insert(idx, code)

# --- AdvanceCommitIndex (in NotifyCommitIndex) ---
# The unique pattern: CHECK_OK(pending_->AdvanceCommittedIndex(commit_index));
# followed by: if (cmeta_->active_role() == RaftPeerPB::LEADER)
idx = find_line(lines, 'CHECK_OK(pending_->AdvanceCommittedIndex(commit_index));')
code = """
  // --- TLA+ trace: AdvanceCommitIndex ---
  if (tla_trace::IsEnabled() && cmeta_->active_role() == RaftPeerPB::LEADER) {
    tla_trace::TraceState tci;
    tci.term = CurrentTermUnlocked();
    tci.role = "Leader";
    tci.votedFor = tla_trace::Nid(peer_uuid());
    tci.commitIndex = pending_->GetCommittedIndex();
    OpId tci_last = queue_->GetLastOpIdInLog();
    tci.lastLogIndex = tci_last.index();
    tci.lastLogTerm = tci_last.term();
    tla_trace::TraceEvent("AdvanceCommitIndex")
        .Node(tla_trace::Nid(peer_uuid()))
        .State(tci)
        .Emit();
  }
"""
lines.insert(idx + 1, code)

# --- HandleAppendEntriesRequest (ONLY in UpdateReplica) ---
# Unique context: "last_received_cur_leader_ = last_from_leader;" is just before
# the FillConsensusResponseOKUnlocked call in UpdateReplica
idx = find_line(lines, 'last_received_cur_leader_ = last_from_leader;')
# Find the FillConsensusResponseOKUnlocked after this
idx = find_line_after(lines, 'FillConsensusResponseOKUnlocked(response);', idx)
code = """
    // --- TLA+ trace: HandleAppendEntriesRequest ---
    if (tla_trace::IsEnabled()) {
      tla_trace::TraceState tae;
      tae.term = CurrentTermUnlocked();
      tae.role = "Follower";
      tae.votedFor = HasVotedCurrentTermUnlocked()
          ? tla_trace::Nid(GetVotedForCurrentTermUnlocked()) : "";
      tae.commitIndex = pending_->GetCommittedIndex();
      OpId tae_last = queue_->GetLastOpIdInLog();
      tae.lastLogIndex = tae_last.index();
      tae.lastLogTerm = tae_last.term();
      tla_trace::TraceEvent("HandleAppendEntriesRequest")
          .Node(tla_trace::Nid(peer_uuid()))
          .State(tae)
          .MsgStr("from", tla_trace::Nid(request->caller_uuid()))
          .MsgStr("to", tla_trace::Nid(peer_uuid()))
          .MsgInt("term", request->caller_term())
          .MsgInt("prevLogIndex", request->preceding_id().index())
          .MsgInt("prevLogTerm", request->preceding_id().term())
          .Emit();
    }
"""
lines.insert(idx + 1, code)

# --- HandleRequestVoteRequest: instrument each respond method ---
def vote_trace_code(granted_str, unique_context):
    return f"""
  // --- TLA+ trace: HandleRequestVoteRequest ---
  if (tla_trace::IsEnabled()) {{
    tla_trace::TraceState trv;
    trv.term = CurrentTermUnlocked();
    trv.role = tla_trace::RoleStr(cmeta_->active_role());
    trv.votedFor = HasVotedCurrentTermUnlocked()
        ? tla_trace::Nid(GetVotedForCurrentTermUnlocked()) : "";
    trv.commitIndex = pending_->GetCommittedIndex();
    OpId trv_last = queue_->GetLastOpIdInLog();
    trv.lastLogIndex = trv_last.index();
    trv.lastLogTerm = trv_last.term();
    tla_trace::TraceEvent("HandleRequestVoteRequest")
        .Node(tla_trace::Nid(peer_uuid()))
        .State(trv)
        .MsgStr("from", tla_trace::Nid(request->candidate_uuid()))
        .MsgStr("to", tla_trace::Nid(peer_uuid()))
        .MsgInt("term", request->candidate_term())
        .MsgBool("preElection", request->is_pre_election())
        .MsgBool("voteGranted", {granted_str})
        .Emit();
  }}
"""

vote_points = [
    ("Denying vote to candidate $1 for earlier term", "false"),
    ("Already granted yes vote for candidate", "true"),
    ("Already voted for candidate $3 in this term", "false"),
    ("which is greater than that of the", "false"),
    ("Granting yes vote for candidate $1 in term", "true"),
]

for pattern, granted in vote_points:
    idx = find_line(lines, pattern)
    # Find "return Status::OK();" after the pattern
    ret_idx = find_line_after(lines, 'return Status::OK();', idx)
    lines.insert(ret_idx, vote_trace_code(granted, pattern))

write_file(RC, lines)
print(f"  Instrumented {RC}")

# ===========================================================================
# consensus_peers.cc
# ===========================================================================
CP = f"{CONSENSUS}/consensus_peers.cc"
lines = read_file(CP)

idx = find_line(lines, '#include "kudu/consensus/multi_raft_batcher.h"')
lines.insert(idx + 1, '#include "kudu/consensus/tla_trace.h"\n')

# Insert before controller_.Reset(); in SendNextRequest
# Find it after "Sending to peer" VLOG
vlog_idx = find_line(lines, 'Sending to peer')
ctrl_idx = find_line_after(lines, 'controller_.Reset();', vlog_idx)
code = """
  // --- TLA+ trace: SendEntries ---
  // req_has_ops already defined above (line 320 in original)
  if (tla_trace::IsEnabled() && req_has_ops) {
    tla_trace::TraceState tse;
    tse.term = request_.caller_term();
    tse.role = "Leader";
    tse.is_weak = true;
    tla_trace::TraceEvent("SendEntries")
        .Node(tla_trace::Nid(leader_uuid_))
        .State(tse)
        .MsgStr("from", tla_trace::Nid(leader_uuid_))
        .MsgStr("to", tla_trace::Nid(peer_pb_.permanent_uuid()))
        .MsgInt("term", request_.caller_term())
        .MsgInt("prevLogIndex", request_.preceding_id().index())
        .MsgInt("prevLogTerm", request_.preceding_id().term())
        .MsgInt("numEntries", request_.ops_size())
        .MsgInt("commitIndex", request_.committed_index())
        .Emit();
  }
"""
lines.insert(ctrl_idx, code)

write_file(CP, lines)
print(f"  Instrumented {CP}")

# ===========================================================================
# consensus_queue.cc
# ===========================================================================
CQ = f"{CONSENSUS}/consensus_queue.cc"
lines = read_file(CQ)

idx = find_line(lines, '#include "kudu/consensus/time_manager.h"')
lines.insert(idx + 1, '#include "kudu/consensus/tla_trace.h"\n')

# Insert after "Received Response from Peer" VLOG
idx = find_line(lines, 'Received Response from Peer')
# Find the closing of the VLOG statement (look for line with just closing paren + semicolon)
while 'SecureShortDebugString(response)' not in lines[idx]:
    idx += 1
code = """
    // --- TLA+ trace: HandleAppendEntriesResponse ---
    if (tla_trace::IsEnabled() && queue_state_.mode == LEADER && peer_uuid != local_peer_pb_.permanent_uuid()) {
      bool ae_ok = (peer->last_exchange_status == PeerStatus::OK);
      tla_trace::TraceState tar;
      tar.term = queue_state_.current_term;
      tar.role = (queue_state_.mode == LEADER) ? "Leader" : "Follower";
      tar.is_weak = true;
      tla_trace::TraceEvent("HandleAppendEntriesResponse")
          .Node(tla_trace::Nid(local_peer_pb_.permanent_uuid()))
          .State(tar)
          .MsgStr("from", tla_trace::Nid(peer_uuid))
          .MsgStr("to", tla_trace::Nid(local_peer_pb_.permanent_uuid()))
          .MsgInt("matchIndex", peer->last_received.index())
          .MsgBool("success", ae_ok)
          .Emit();
    }
"""
lines.insert(idx + 1, code)

write_file(CQ, lines)
print(f"  Instrumented {CQ}")

# ===========================================================================
# leader_election.cc
# ===========================================================================
LE = f"{CONSENSUS}/leader_election.cc"
lines = read_file(LE)

idx = find_line(lines, '#include "kudu/consensus/leader_election.h"')
lines.insert(idx + 1, '#include "kudu/consensus/tla_trace.h"\n')

# Insert before "Check for a decision outside the lock."
idx = find_line(lines, 'Check for a decision outside the lock.')
code = """
  // --- TLA+ trace: HandleRequestVoteResponse (remote vote) ---
  if (tla_trace::IsEnabled()) {
    bool is_pre = request_.is_pre_election();
    int64_t cand_term = is_pre ? request_.candidate_term() - 1
                               : request_.candidate_term();
    tla_trace::TraceState tvr;
    tvr.term = cand_term;
    tvr.role = "Candidate";
    tvr.votedFor = is_pre ? "" : tla_trace::Nid(request_.candidate_uuid());
    tvr.commitIndex = trace_commit_index_;
    tvr.lastLogIndex = request_.candidate_status().last_received().index();
    tvr.lastLogTerm = request_.candidate_status().last_received().term();
    bool vote_ok = false;
    int64_t resp_term = cand_term;
    {
      std::lock_guard trace_guard(lock_);
      VoterState* vst = FindOrDie(voter_state_, voter_uuid).get();
      vote_ok = vst->response.vote_granted();
      if (vst->response.has_responder_term()) {
        resp_term = vst->response.responder_term();
      }
    }
    tla_trace::TraceEvent("HandleRequestVoteResponse")
        .Node(tla_trace::Nid(request_.candidate_uuid()))
        .State(tvr)
        .MsgStr("from", tla_trace::Nid(voter_uuid))
        .MsgStr("to", tla_trace::Nid(request_.candidate_uuid()))
        .MsgBool("voteGranted", vote_ok)
        .MsgInt("term", resp_term)
        .Emit();
  }
"""
lines.insert(idx, code)

write_file(LE, lines)
print(f"  Instrumented {LE}")

# ===========================================================================
# leader_election.h — add trace_commit_index_ field and setter
# ===========================================================================
LEH = f"{CONSENSUS}/leader_election.h"
lines = read_file(LEH)

if 'trace_commit_index_' not in ''.join(lines):
    # Add SetTraceCommitIndex after Run()
    idx = find_line(lines, 'void Run();')
    lines.insert(idx + 1, '\n  // TLA+ trace: candidate commit index at election start.\n  void SetTraceCommitIndex(int64_t ci) { trace_commit_index_ = ci; }\n')
    # Add field after start_time_
    idx = find_line(lines, 'MonoTime start_time_;')
    lines.insert(idx + 1, '\n  // TLA+ trace: commit index at election start.\n  int64_t trace_commit_index_ = 0;\n')
    write_file(LEH, lines)
    print(f"  Instrumented {LEH}")

print("Done.")
PYEOF

echo "=== Instrumentation applied successfully ==="
