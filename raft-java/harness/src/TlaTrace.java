package com.github.wenweihu86.raft;

import java.io.*;
import java.time.Instant;
import java.util.List;

/**
 * TLA+ trace emission for raft-java.
 * Activated by setting RAFT_TRACE_FILE environment variable or calling init(path).
 * Thread-safe: all emit calls synchronize on an internal lock.
 */
public class TlaTrace {

    private static PrintWriter writer;
    private static final Object lock = new Object();
    private static volatile boolean enabled = false;
    /** Last emitted JSON (sans timestamp) for deduplication of brpc-java retries. */
    private static String lastEventKey = "";

    /** Initialize from RAFT_TRACE_FILE environment variable. */
    public static void init() {
        String path = System.getenv("RAFT_TRACE_FILE");
        if (path != null && !path.isEmpty()) {
            init(path);
        }
    }

    /** Initialize with explicit file path. */
    public static void init(String path) {
        synchronized (lock) {
            try {
                writer = new PrintWriter(new BufferedWriter(new FileWriter(path, false)));
                enabled = true;
            } catch (IOException e) {
                System.err.println("TlaTrace: failed to open " + path + ": " + e.getMessage());
            }
        }
    }

    /** Flush and close the trace file. */
    public static void close() {
        synchronized (lock) {
            if (writer != null) {
                writer.flush();
                writer.close();
                writer = null;
                enabled = false;
            }
        }
    }

    public static boolean isEnabled() {
        return enabled;
    }

    // --- Helpers ---

    private static String nid(int serverId) {
        return "s" + serverId;
    }

    private static String roleStr(RaftNode.NodeState state) {
        switch (state) {
            case STATE_FOLLOWER:       return "Follower";
            case STATE_PRE_CANDIDATE:  return "PreCandidate";
            case STATE_CANDIDATE:      return "Candidate";
            case STATE_LEADER:         return "Leader";
            default:                   return "Unknown";
        }
    }

    private static String votedForStr(int votedFor) {
        return votedFor == 0 ? "" : nid(votedFor);
    }

    private static String ts() {
        return Instant.now().toString();
    }

    /** Build state JSON fragment. Always emits all fields (Trace.tla ignores extras). */
    private static String stateJson(RaftNode node) {
        return String.format(
            "\"term\":%d,\"role\":\"%s\",\"votedFor\":\"%s\",\"commitIndex\":%d,\"lastLogIndex\":%d,\"lastLogTerm\":%d",
            node.getCurrentTerm(),
            roleStr(node.getState()),
            votedForStr(node.getVotedFor()),
            node.getCommitIndex(),
            node.getRaftLog().getLastLogIndex(),
            node.getLastLogTerm()
        );
    }

    /** Build msg JSON fragment with from/to. */
    private static String msgJson(int fromId, int toId) {
        return String.format("\"msg\":{\"from\":\"%s\",\"to\":\"%s\"}", nid(fromId), nid(toId));
    }

    /** Write one NDJSON line, deduplicating consecutive identical events.
     *  brpc-java sometimes retries RPCs, causing the same handler to fire twice.
     *  We compare by stripping the timestamp to detect duplicates. */
    private static void emit(String json) {
        synchronized (lock) {
            if (writer != null) {
                // Strip timestamp for dedup comparison: remove "ts":"..." portion
                String key = json.replaceFirst("\"ts\":\"[^\"]*\"", "\"ts\":\"X\"");
                if (key.equals(lastEventKey)) {
                    return; // duplicate — skip
                }
                lastEventKey = key;
                writer.println(json);
                writer.flush();
            }
        }
    }

    // --- Event Emitters ---

    /** StartPreVote: after state = PRE_CANDIDATE. */
    public static void emitStartPreVote(RaftNode node) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"StartPreVote\",\"nid\":\"%s\",\"state\":{%s}}}",
            ts(), nid(nid), stateJson(node)));
    }

    /** HandlePreVoteRequest: follower processes pre-vote request. */
    public static void emitHandlePreVoteRequest(RaftNode node, int fromServerId) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"HandlePreVoteRequest\",\"nid\":\"%s\",\"state\":{%s},%s}}",
            ts(), nid(nid), stateJson(node), msgJson(fromServerId, nid)));
    }

    /** HandlePreVoteResponse: candidate processes pre-vote response. */
    public static void emitHandlePreVoteResponse(RaftNode node, int fromServerId) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"HandlePreVoteResponse\",\"nid\":\"%s\",\"state\":{%s},%s}}",
            ts(), nid(nid), stateJson(node), msgJson(fromServerId, nid)));
    }

    /** StartVote: after term++, votedFor set. */
    public static void emitStartVote(RaftNode node) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"StartVote\",\"nid\":\"%s\",\"state\":{%s}}}",
            ts(), nid(nid), stateJson(node)));
    }

    /** HandleRequestVoteRequest: server processes vote request. */
    public static void emitHandleRequestVoteRequest(RaftNode node, int fromServerId) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"HandleRequestVoteRequest\",\"nid\":\"%s\",\"state\":{%s},%s}}",
            ts(), nid(nid), stateJson(node), msgJson(fromServerId, nid)));
    }

    /** HandleRequestVoteResponse: candidate processes vote response. */
    public static void emitHandleRequestVoteResponse(RaftNode node, int fromServerId) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"HandleRequestVoteResponse\",\"nid\":\"%s\",\"state\":{%s},%s}}",
            ts(), nid(nid), stateJson(node), msgJson(fromServerId, nid)));
    }

    /** BecomeLeader: after state = LEADER. */
    public static void emitBecomeLeader(RaftNode node) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"BecomeLeader\",\"nid\":\"%s\",\"state\":{%s}}}",
            ts(), nid(nid), stateJson(node)));
    }

    /** ClientRequest: leader appends client entry. */
    public static void emitClientRequest(RaftNode node) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"ClientRequest\",\"nid\":\"%s\",\"state\":{%s}}}",
            ts(), nid(nid), stateJson(node)));
    }

    /** AppendEntries: leader sends entries to peer. */
    public static void emitAppendEntries(RaftNode node, int toServerId) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"AppendEntries\",\"nid\":\"%s\",\"state\":{%s},%s}}",
            ts(), nid(nid), stateJson(node), msgJson(nid, toServerId)));
    }

    /** HandleAppendEntriesRequest: follower processes append entries. */
    public static void emitHandleAppendEntriesRequest(RaftNode node, int fromServerId) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"HandleAppendEntriesRequest\",\"nid\":\"%s\",\"state\":{%s},%s}}",
            ts(), nid(nid), stateJson(node), msgJson(fromServerId, nid)));
    }

    /** HandleAppendEntriesResponse: leader processes append response. */
    public static void emitHandleAppendEntriesResponse(RaftNode node, int fromServerId) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"HandleAppendEntriesResponse\",\"nid\":\"%s\",\"state\":{%s},%s}}",
            ts(), nid(nid), stateJson(node), msgJson(fromServerId, nid)));
    }

    /** AdvanceCommitIndex: leader advances commit. */
    public static void emitAdvanceCommitIndex(RaftNode node) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"AdvanceCommitIndex\",\"nid\":\"%s\",\"state\":{%s}}}",
            ts(), nid(nid), stateJson(node)));
    }

    /** SendInstallSnapshot: leader sends snapshot. */
    public static void emitSendInstallSnapshot(RaftNode node, int toServerId) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"SendInstallSnapshot\",\"nid\":\"%s\",\"state\":{%s},%s}}",
            ts(), nid(nid), stateJson(node), msgJson(nid, toServerId)));
    }

    /** HandleInstallSnapshotRequest: follower processes snapshot. */
    public static void emitHandleInstallSnapshotRequest(RaftNode node, int fromServerId) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"HandleInstallSnapshotRequest\",\"nid\":\"%s\",\"state\":{%s},%s}}",
            ts(), nid(nid), stateJson(node), msgJson(fromServerId, nid)));
    }

    /** HandleInstallSnapshotResponse: leader processes snapshot response. */
    public static void emitHandleInstallSnapshotResponse(RaftNode node, int fromServerId) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"HandleInstallSnapshotResponse\",\"nid\":\"%s\",\"state\":{%s},%s}}",
            ts(), nid(nid), stateJson(node), msgJson(fromServerId, nid)));
    }

    /** TakeSnapshot: server takes snapshot. */
    public static void emitTakeSnapshot(RaftNode node) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"TakeSnapshot\",\"nid\":\"%s\",\"state\":{%s}}}",
            ts(), nid(nid), stateJson(node)));
    }

    /** ProposeConfigChange: leader proposes config change. */
    public static void emitProposeConfigChange(RaftNode node, List<Integer> newConfig) {
        if (!enabled) return;
        int nid = node.getLocalServer().getServerId();
        StringBuilder sb = new StringBuilder("[");
        for (int k = 0; k < newConfig.size(); k++) {
            if (k > 0) sb.append(",");
            sb.append("\"").append(nid(newConfig.get(k))).append("\"");
        }
        sb.append("]");
        emit(String.format(
            "{\"tag\":\"trace\",\"ts\":\"%s\",\"event\":{\"name\":\"ProposeConfigChange\",\"nid\":\"%s\",\"state\":{%s},\"config\":%s}}",
            ts(), nid(nid), stateJson(node), sb.toString()));
    }
}
