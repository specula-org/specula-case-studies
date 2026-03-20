#!/usr/bin/env python3
"""Instrument raft.rs with TLA+ trace emission calls.

Each patch is a (find_pattern, replace_pattern) pair applied via str.replace().
Patterns must be unique in the file. The script verifies uniqueness and reports
any mismatches.
"""

import sys
import os


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path-to-raft.rs>")
        sys.exit(1)

    path = sys.argv[1]
    with open(path) as f:
        content = f.read()

    patches = [
        # ============================================================
        # 1. Timeout — after self.hup(false) in step() MsgHup handler
        # ============================================================
        (
            '            MessageType::MsgHup => self.hup(false),',
            '            MessageType::MsgHup => { self.hup(false); tla_trace_event!("Timeout", self); }',
        ),

        # ============================================================
        # 2. BecomeLeader — REMOVED: fires inside poll() before HandleRequestVoteResponse
        # trace. The spec's HandleRequestVoteResponse handles BecomeLeader internally.
        # ============================================================

        # ============================================================
        # 3+5. HandleRequestVoteRequest / HandleRequestPreVoteRequest — GRANT branch
        # ============================================================
        (
            '                    if m.get_msg_type() == MessageType::MsgRequestVote {\n'
            '                        // Only record real votes.\n'
            '                        self.election_elapsed = 0;\n'
            '                        self.vote = m.from;\n'
            '                    }',
            '                    if m.get_msg_type() == MessageType::MsgRequestVote {\n'
            '                        // Only record real votes.\n'
            '                        self.election_elapsed = 0;\n'
            '                        self.vote = m.from;\n'
            '                    }\n'
            '                    {\n'
            '                        let ename = if m.get_msg_type() == MessageType::MsgRequestVote { "HandleRequestVoteRequest" } else { "HandleRequestPreVoteRequest" };\n'
            '                        tla_trace_event!(ename, self, &format!(r#","from":{},"granted":true"#, m.from));\n'
            '                    }',
        ),

        # ============================================================
        # 3+5. HandleRequestVoteRequest / HandleRequestPreVoteRequest — REJECT branch
        # ============================================================
        (
            '                    self.r.send(to_send, &mut self.msgs);\n'
            '                    self.maybe_commit_by_vote(&m);\n'
            '                }\n'
            '            }',
            '                    self.r.send(to_send, &mut self.msgs);\n'
            '                    self.maybe_commit_by_vote(&m);\n'
            '                    {\n'
            '                        let ename = if m.get_msg_type() == MessageType::MsgRequestVote { "HandleRequestVoteRequest" } else { "HandleRequestPreVoteRequest" };\n'
            '                        tla_trace_event!(ename, self, &format!(r#","from":{},"granted":false"#, m.from));\n'
            '                    }\n'
            '                }\n'
            '            }',
        ),

        # ============================================================
        # 4+6. HandleRequestVoteResponse / HandleRequestPreVoteResponse
        # ============================================================
        (
            '                self.poll(m.from, m.get_msg_type(), !m.reject);\n'
            '                self.maybe_commit_by_vote(&m);\n'
            '            }',
            '                self.poll(m.from, m.get_msg_type(), !m.reject);\n'
            '                self.maybe_commit_by_vote(&m);\n'
            '                {\n'
            '                    let ename = if m.get_msg_type() == MessageType::MsgRequestVoteResponse { "HandleRequestVoteResponse" } else { "HandleRequestPreVoteResponse" };\n'
            '                    tla_trace_event!(ename, self, &format!(r#","from":{},"granted":{}"#, m.from, !m.reject));\n'
            '                }\n'
            '            }',
        ),

        # ============================================================
        # 7. ClientRequest — after bcast_append() in MsgPropose handler
        # ============================================================
        (
            '                self.bcast_append();\n'
            '                return Ok(());\n'
            '            }\n'
            '            MessageType::MsgReadIndex',
            '                self.bcast_append();\n'
            '                tla_trace_event!("ClientRequest", self);\n'
            '                return Ok(());\n'
            '            }\n'
            '            MessageType::MsgReadIndex',
        ),

        # ============================================================
        # 8. HandleAppendEntriesRequest — after send in handle_append_entries (main path)
        # ============================================================
        (
            '        to_send.set_commit(self.raft_log.committed);\n'
            '        self.r.send(to_send, &mut self.msgs);\n'
            '    }\n\n'
            '    // TODO: revoke pub when there is a better way to test.\n'
            '    /// For a message, commit and send out heartbeat.',
            '        let _tla_accepted = !to_send.reject;\n'
            '        to_send.set_commit(self.raft_log.committed);\n'
            '        self.r.send(to_send, &mut self.msgs);\n'
            '        tla_trace_event!("HandleAppendEntriesRequest", self, &format!(r#","from":{}"#, m.from));\n'
            '    }\n\n'
            '    // TODO: revoke pub when there is a better way to test.\n'
            '    /// For a message, commit and send out heartbeat.',
        ),

        # ============================================================
        # 9a. HandleAppendEntriesResponse — reject branch (before return)
        # ============================================================
        (
            '                self.send_append(m.from);\n'
            '            }\n'
            '            return;\n'
            '        }\n\n'
            '        let old_paused = pr.is_paused();',
            '                self.send_append(m.from);\n'
            '            }\n'
            '            tla_trace_event!("HandleAppendEntriesResponse", self, &format!(r#","from":{},"accepted":false"#, m.from));\n'
            '            return;\n'
            '        }\n\n'
            '        let old_paused = pr.is_paused();',
        ),

        # ============================================================
        # 9b. HandleAppendEntriesResponse — accept branch (BEFORE maybe_commit)
        # Emitted after matchIndex update but before maybe_commit so trace order is:
        #   HandleAppendEntriesResponse → AdvanceCommitIndex (if commit advances)
        # This matches the spec's atomicity: HandleAppendEntriesResponse is separate from AdvanceCommitIndex.
        # ============================================================
        (
            '            ProgressState::Replicate => pr.ins.free_to(m.get_index()),\n'
            '        }\n\n'
            '        if self.maybe_commit() {',
            '            ProgressState::Replicate => pr.ins.free_to(m.get_index()),\n'
            '        }\n'
            '        tla_trace_event!("HandleAppendEntriesResponse", self, &format!(r#","from":{},"accepted":true"#, m.from));\n\n'
            '        if self.maybe_commit() {',
        ),

        # ============================================================
        # 10. SendHeartbeat — after self.send(m, msgs) in send_heartbeat
        # ============================================================
        (
            '        self.send(m, msgs);\n'
            '    }\n'
            '}\n',
            '        self.send(m, msgs);\n'
            '        tla_trace_event!("SendHeartbeat", self, &format!(r#","from":{},"to":{}"#, self.id, to));\n'
            '    }\n'
            '}\n',
        ),

        # ============================================================
        # 11. HandleHeartbeatRequest — after send in handle_heartbeat
        # ============================================================
        (
            '        self.r.send(to_send, &mut self.msgs);\n'
            '    }\n\n'
            '    fn handle_snapshot',
            '        self.r.send(to_send, &mut self.msgs);\n'
            '        tla_trace_event!("HandleHeartbeatRequest", self, &format!(r#","from":{}"#, m.from));\n'
            '    }\n\n'
            '    fn handle_snapshot',
        ),

        # ============================================================
        # 12. HandleHeartbeatResponse — after pr is last used (before read_only check)
        # ============================================================
        (
            '            self.r.send_append(m.from, pr, &mut self.msgs);\n'
            '        }\n\n'
            '        if self.read_only.option != ReadOnlyOption::Safe',
            '            self.r.send_append(m.from, pr, &mut self.msgs);\n'
            '        }\n'
            '        tla_trace_event!("HandleHeartbeatResponse", self, &format!(r#","from":{}"#, m.from));\n\n'
            '        if self.read_only.option != ReadOnlyOption::Safe',
        ),

        # ============================================================
        # 13. TransferLeadership — after lead_transferee set
        # ============================================================
        (
            '        self.lead_transferee = Some(lead_transferee);\n'
            '        let pr = self.prs.get_mut(from).unwrap();',
            '        self.lead_transferee = Some(lead_transferee);\n'
            '        tla_trace_event!("TransferLeadership", self, &format!(r#","target":{}"#, lead_transferee));\n'
            '        let pr = self.prs.get_mut(from).unwrap();',
        ),

        # ============================================================
        # 14. HandleTimeoutNowRequest — after self.hup(true)
        # ============================================================
        (
            '                    self.hup(true);\n'
            '                } else {',
            '                    self.hup(true);\n'
            '                    tla_trace_event!("HandleTimeoutNowRequest", self, &format!(r#","from":{}"#, m.from));\n'
            '                } else {',
        ),

        # ============================================================
        # 15. CheckQuorum — after potential step-down
        # ============================================================
        (
            '                    self.become_follower(term, INVALID_ID);\n'
            '                }\n'
            '                return Ok(());\n'
            '            }\n'
            '            MessageType::MsgPropose',
            '                    self.become_follower(term, INVALID_ID);\n'
            '                }\n'
            '                tla_trace_event!("CheckQuorum", self);\n'
            '                return Ok(());\n'
            '            }\n'
            '            MessageType::MsgPropose',
        ),

        # ============================================================
        # 16. PersistEntries — after maybe_persist succeeds
        # ============================================================
        (
            '        let update = self.raft_log.maybe_persist(index, term);\n'
            '        if update && self.state == StateRole::Leader {',
            '        let update = self.raft_log.maybe_persist(index, term);\n'
            '        if update { tla_trace_event!("PersistEntries", self); }\n'
            '        if update && self.state == StateRole::Leader {',
        ),

        # ============================================================
        # 17. AdvanceCommitIndex — inside maybe_commit when returning true
        # ============================================================
        (
            '                .update_committed(committed);\n'
            '            return true;\n'
            '        }\n'
            '        false\n'
            '    }',
            '                .update_committed(committed);\n'
            '            tla_trace_event!("AdvanceCommitIndex", self);\n'
            '            return true;\n'
            '        }\n'
            '        false\n'
            '    }',
        ),
    ]

    applied = 0
    failed = 0
    for i, (pattern, replacement) in enumerate(patches, 1):
        count = content.count(pattern)
        if count == 0:
            print(f"  ERROR: patch {i} pattern not found")
            print(f"    First 80 chars: {repr(pattern[:80])}")
            failed += 1
            continue
        if count > 1:
            print(f"  ERROR: patch {i} pattern found {count} times (must be unique)")
            failed += 1
            continue
        content = content.replace(pattern, replacement)
        applied += 1

    with open(path, 'w') as f:
        f.write(content)

    print(f"Patched {path}: {applied} applied, {failed} failed out of {len(patches)}")
    if failed > 0:
        sys.exit(1)


if __name__ == '__main__':
    main()
