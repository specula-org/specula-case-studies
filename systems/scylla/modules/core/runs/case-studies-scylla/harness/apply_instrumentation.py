#!/usr/bin/env python3
"""
Apply TLA+ trace instrumentation to ScyllaDB raft/fsm.cc and raft/fsm.hh.

Usage: python3 apply_instrumentation.py <scylla_root>

Instrument points are inserted from bottom to top so that line offsets
don't shift. Each insertion uses a unique anchor string from the source.
"""
import sys
import os
import shutil

def read_file(path):
    with open(path, 'r') as f:
        return f.readlines()

def write_file(path, lines):
    with open(path, 'w') as f:
        f.writelines(lines)

def find_line(lines, anchor, occurrence=1):
    """Find line index containing anchor (1-based occurrence). Returns -1 if not found."""
    count = 0
    for i, line in enumerate(lines):
        if anchor in line:
            count += 1
            if count == occurrence:
                return i
    return -1

def insert_lines_after(lines, idx, text):
    """Insert text lines after lines[idx]."""
    new_lines = [l + '\n' for l in text.split('\n')]
    for j, nl in enumerate(new_lines):
        lines.insert(idx + 1 + j, nl)

def insert_lines_before(lines, idx, text):
    """Insert text lines before lines[idx]."""
    new_lines = [l + '\n' for l in text.split('\n')]
    for j, nl in enumerate(new_lines):
        lines.insert(idx + j, nl)


# ===========================================================================
# Define all insertion points for fsm.cc
# Each entry: (anchor_string, occurrence, "after"|"before", code_to_insert)
# Processed in REVERSE ORDER so earlier insertions don't shift later ones.
# ===========================================================================

FSM_CC_INSERTIONS = [
    # --- 0. Include + macros (top of file) ---
    (
        '#include "utils/error_injection.hh"', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
#include "raft/tla_trace.hh"
#define TLA_NID(sid) ((sid).id.get_least_significant_bits())
#define TLA_ROLE_STR() (is_leader() ? "Leader" : (is_candidate() ? "Candidate" : "Follower"))
#define TLA_I64(x) static_cast<int64_t>((x).value())
#endif"""
    ),

    # --- 2.3 ClientRequest: after _sm_events.signal() in add_entry (1st occurrence) ---
    (
        '_sm_events.signal();', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
    if constexpr (!std::is_same_v<T, configuration>) {
        if (tla_trace::enabled())
            tla_trace::emit_client_request(
                TLA_NID(_my_id), TLA_I64(_current_term), TLA_ROLE_STR(),
                TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
                TLA_I64(_log.last_term()));
    }
#endif"""
    ),

    # --- 2.2 BecomeLeader: after logger.trace closing line in become_leader() ---
    (
        '_my_id, _log.stable_idx(), _log.last_idx());', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
    if (tla_trace::enabled())
        tla_trace::emit_become_leader(
            TLA_NID(_my_id), TLA_I64(_current_term), TLA_ROLE_STR(),
            TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
            TLA_I64(_log.last_term()));
#endif"""
    ),

    # --- 2.1 Timeout: before "if (votes.tally_votes() == vote_result::WON)" in become_candidate ---
    (
        'if (votes.tally_votes() == vote_result::WON)', 1, "before",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
    if (!is_prevote && tla_trace::enabled())
        tla_trace::emit_timeout(
            TLA_NID(_my_id), TLA_I64(_current_term), TLA_ROLE_STR(),
            TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
            TLA_I64(_log.last_term()));
#endif"""
    ),

    # --- 2.9 MaybeCommit: after "_commit_idx = new_commit_idx;" (2nd occurrence, in maybe_commit) ---
    (
        '_commit_idx = new_commit_idx;', 2, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
    if (tla_trace::enabled())
        tla_trace::emit_maybe_commit(
            TLA_NID(_my_id), TLA_I64(_current_term), TLA_ROLE_STR(),
            TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
            TLA_I64(_log.last_term()));
#endif"""
    ),

    # --- 2.5 HandleAppendEntriesRequest: after accepted reply in append_entries() ---
    (
        'send_to(from, append_reply{_current_term, _commit_idx, append_reply::accepted{last_new_idx}});', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
    if (tla_trace::enabled())
        tla_trace::emit_handle_ae_request(
            TLA_NID(_my_id), TLA_NID(from),
            TLA_I64(_current_term), TLA_ROLE_STR(),
            TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
            TLA_I64(_log.last_term()));
#endif"""
    ),

    # --- 2.6 HandleAppendEntriesResponse: after replicate_to in append_entries_reply() ---
    (
        'replicate_to(*opt_progress, false);', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
    if (tla_trace::enabled()) {
        bool _tla_ok = std::holds_alternative<append_reply::accepted>(reply.result);
        int64_t _tla_mi = _tla_ok ? TLA_I64(std::get<append_reply::accepted>(reply.result).last_new_idx) : 0;
        tla_trace::emit_handle_ae_response(
            TLA_NID(_my_id), TLA_NID(from),
            TLA_I64(_current_term), TLA_ROLE_STR(),
            TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
            TLA_I64(_log.last_term()), _tla_ok, _tla_mi);
    }
#endif"""
    ),

    # --- 2.7 HandleRequestVoteRequest (granted): after grant vote reply ---
    (
        'send_to(from, vote_reply{request.current_term, true, request.is_prevote});', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
        if (!request.is_prevote && tla_trace::enabled())
            tla_trace::emit_handle_rv_request(
                TLA_NID(_my_id), TLA_NID(from),
                TLA_I64(_current_term), TLA_ROLE_STR(),
                TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
                TLA_I64(_log.last_term()), true);
#endif"""
    ),

    # --- 2.7 HandleRequestVoteRequest (denied): after deny vote reply ---
    (
        'send_to(from, vote_reply{_current_term, false, request.is_prevote});', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
        if (!request.is_prevote && tla_trace::enabled())
            tla_trace::emit_handle_rv_request(
                TLA_NID(_my_id), TLA_NID(from),
                TLA_I64(_current_term), TLA_ROLE_STR(),
                TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
                TLA_I64(_log.last_term()), false);
#endif"""
    ),

    # --- 2.8 HandleRequestVoteResponse (won, real vote): after "won vote" log ---
    (
        'logger.trace("request_vote_reply[{}] won vote", _my_id);', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
            if (tla_trace::enabled())
                tla_trace::emit_handle_rv_response(
                    TLA_NID(_my_id), TLA_NID(from),
                    TLA_I64(_current_term), TLA_ROLE_STR(),
                    TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
                    TLA_I64(_log.last_term()), true);
#endif"""
    ),

    # --- 2.8 HandleRequestVoteResponse (lost): after become_follower in LOST case ---
    # This is "become_follower(server_id{});" specifically in request_vote_reply
    # It's the 5th occurrence of become_follower(server_id{})
    (
        'become_follower(server_id{});', 5, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
        if (tla_trace::enabled())
            tla_trace::emit_handle_rv_response(
                TLA_NID(_my_id), TLA_NID(from),
                TLA_I64(_current_term), TLA_ROLE_STR(),
                TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
                TLA_I64(_log.last_term()), false);
#endif"""
    ),

    # --- 2.4 AppendEntries: BEFORE send_to(progress.id, std::move(req)) ---
    # Must be before because req is moved-from after send_to
    (
        'send_to(progress.id, std::move(req));', 1, "before",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
        if (tla_trace::enabled())
            tla_trace::emit_append_entries(
                TLA_NID(_my_id), TLA_NID(progress.id),
                TLA_I64(_current_term), TLA_ROLE_STR(),
                TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
                TLA_I64(_log.last_term()),
                TLA_I64(req.current_term),
                TLA_I64(req.prev_log_idx),
                TLA_I64(req.prev_log_term),
                static_cast<int64_t>(req.entries.size()),
                TLA_I64(req.leader_commit_idx));
#endif"""
    ),

    # --- 2.13 SendInstallSnapshot: after send_to(progress.id, install_snapshot{...}) ---
    (
        'send_to(progress.id, install_snapshot{_current_term, snapshot});', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
            if (tla_trace::enabled())
                tla_trace::emit_send_install_snapshot(
                    TLA_NID(_my_id), TLA_NID(progress.id),
                    TLA_I64(_current_term), TLA_ROLE_STR(),
                    TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
                    TLA_I64(_log.last_term()),
                    TLA_I64(snapshot.idx), TLA_I64(snapshot.term));
#endif"""
    ),

    # --- 2.14/2.15 HandleInstallSnapshot / TakeLocalSnapshot: before "return true" in apply_snapshot ---
    (
        'return true;', 1, "before",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
    if (tla_trace::enabled()) {
        if (local)
            tla_trace::emit_take_local_snapshot(
                TLA_NID(_my_id), TLA_I64(_current_term), TLA_ROLE_STR(),
                TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
                TLA_I64(_log.last_term()),
                TLA_I64(_log.get_snapshot().idx),
                TLA_I64(_log.get_snapshot().term));
        else
            tla_trace::emit_handle_install_snapshot(
                TLA_NID(_my_id), 0,
                TLA_I64(_current_term), TLA_ROLE_STR(),
                TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
                TLA_I64(_log.last_term()));
    }
#endif"""
    ),

    # --- 2.10 BroadcastReadQuorum: after the for loop in broadcast_read_quorum ---
    # Unique anchor: closing of broadcast_read_quorum function
    # Use the send_to(p.id, read_quorum{...}) line as anchor — it's the last in the for loop
    (
        'send_to(p.id, read_quorum{_current_term, std::min(p.match_idx, _commit_idx), id});', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
                // Trace emitted per-send; final emit after loop.
#endif"""
    ),

    # --- 2.12 HandleReadQuorumResponse: after "new commit read" log ---
    (
        'logger.trace("handle_read_quorum_reply[{}] new commit read {}", _my_id, new_committed_read);', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
    if (tla_trace::enabled())
        tla_trace::emit_handle_rq_response(
            TLA_NID(_my_id), TLA_NID(from),
            TLA_I64(_current_term), TLA_ROLE_STR(),
            TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
            TLA_I64(_log.last_term()),
            TLA_I64(reply.id), TLA_I64(state.max_read_id_with_quorum));
#endif"""
    ),

    # --- 2.16 Crash: in stop() after become_follower ---
    # Anchor: "become_follower({});" — 2nd occurrence is in stop()
    (
        'become_follower({});', 2, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
        if (tla_trace::enabled())
            tla_trace::emit_crash(
                TLA_NID(_my_id), TLA_I64(_current_term), TLA_ROLE_STR(),
                TLA_I64(_commit_idx), TLA_I64(_log.last_idx()),
                TLA_I64(_log.last_term()));
#endif"""
    ),
]

# ===========================================================================
# fsm.hh insertions
# ===========================================================================

FSM_HH_INSERTIONS = [
    # --- Include ---
    (
        '#include "log.hh"', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
#include "raft/tla_trace.hh"
#endif"""
    ),

    # --- 2.17 UpdateTerm: after "update_current_term(msg.current_term);" in step() ---
    (
        'update_current_term(msg.current_term);', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
            if (tla_trace::enabled())
                tla_trace::emit_update_term(
                    _my_id.id.get_least_significant_bits(),
                    static_cast<int64_t>(_current_term.value()),
                    is_leader() ? "Leader" : (is_candidate() ? "Candidate" : "Follower"),
                    static_cast<int64_t>(_commit_idx.value()),
                    static_cast<int64_t>(_log.last_idx().value()),
                    static_cast<int64_t>(_log.last_term().value()));
#endif"""
    ),

    # --- 2.11 HandleReadQuorumRequest: after read_quorum_reply in step(follower) ---
    (
        'send_to(from, read_quorum_reply{_current_term, _commit_idx, msg.id});', 1, "after",
        """#ifdef SCYLLA_TLA_TRACE_ENABLED
        if (tla_trace::enabled())
            tla_trace::emit_handle_rq_request(
                _my_id.id.get_least_significant_bits(),
                from.id.get_least_significant_bits(),
                static_cast<int64_t>(_current_term.value()),
                is_leader() ? "Leader" : (is_candidate() ? "Candidate" : "Follower"),
                static_cast<int64_t>(_commit_idx.value()),
                static_cast<int64_t>(_log.last_idx().value()),
                static_cast<int64_t>(_log.last_term().value()),
                static_cast<int64_t>(msg.id.value()));
#endif"""
    ),
]


def apply_insertions(path, insertions):
    """Apply a list of insertions to a file, processing from bottom to top."""
    lines = read_file(path)

    # Resolve all insertion positions first (on original file)
    resolved = []
    for anchor, occurrence, position, code in insertions:
        idx = find_line(lines, anchor, occurrence)
        if idx < 0:
            print(f"  WARNING: anchor not found (occ={occurrence}): {repr(anchor[:70])}")
            continue
        resolved.append((idx, position, code))

    # Sort by line index DESCENDING so bottom insertions don't shift top ones
    resolved.sort(key=lambda x: x[0], reverse=True)

    for idx, position, code in resolved:
        if position == "after":
            insert_lines_after(lines, idx, code)
        else:
            insert_lines_before(lines, idx, code)

    write_file(path, lines)
    print(f"  Applied {len(resolved)} instrumentation points to {path}")


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 apply_instrumentation.py <scylla_root>")
        sys.exit(1)

    root = sys.argv[1]
    fsm_cc = os.path.join(root, 'raft', 'fsm.cc')
    fsm_hh = os.path.join(root, 'raft', 'fsm.hh')
    tla_trace_dst = os.path.join(root, 'raft', 'tla_trace.hh')

    if not os.path.isfile(fsm_cc):
        print(f"ERROR: {fsm_cc} not found")
        sys.exit(1)

    # Copy trace header into raft/ directory
    harness_src = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'src', 'tla_trace.hh')
    print(f"Copying {harness_src} -> {tla_trace_dst}")
    shutil.copy2(harness_src, tla_trace_dst)

    print("Instrumenting fsm.cc...")
    apply_insertions(fsm_cc, FSM_CC_INSERTIONS)

    print("Instrumenting fsm.hh...")
    apply_insertions(fsm_hh, FSM_HH_INSERTIONS)

    print("\nDone. Build with -DSCYLLA_TLA_TRACE_ENABLED to enable trace emission.")
    print("Set SCYLLA_TLA_TRACE=<output_path> env var at runtime to activate.")


if __name__ == '__main__':
    main()
