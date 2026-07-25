package com.alipay.sofa.jraft.core;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.io.PrintWriter;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.locks.ReentrantLock;

/**
 * TLA+ trace emission for sofa-jraft.
 *
 * Writes flat NDJSON lines, one per event, to the file specified by
 * TLA_TRACE_FILE env var (default /tmp/jraft-trace.ndjson).
 *
 * Every line includes "tag":"trace" (mandatory for Trace.tla filtering),
 * plus the event name, node ID (s1/s2/s3), and state snapshot fields.
 *
 * Thread-safe: single writer protected by ReentrantLock.
 */
public class TlaTrace {

    private static volatile PrintWriter writer;
    private static final ReentrantLock writeLock = new ReentrantLock();
    private static final Map<String, String> nodeMap = new LinkedHashMap<>();
    private static final AtomicInteger nextId = new AtomicInteger(1);
    private static volatile boolean initialized = false;
    private static final Object initLock = new Object();
    /** Nodes that were crashed and are pending restart (emit RestartFromPersisted on next init). */
    private static final Set<String> pendingRestarts = Collections.synchronizedSet(new HashSet<>());

    public static void init(String traceFile) {
        synchronized (initLock) {
            if (initialized) {
                return;
            }
            try {
                File f = new File(traceFile);
                if (f.getParentFile() != null) {
                    f.getParentFile().mkdirs();
                }
                writer = new PrintWriter(new BufferedWriter(new FileWriter(f, false)));
                initialized = true;
            } catch (IOException e) {
                System.err.println("[TlaTrace] Failed to open trace file: " + traceFile + " — " + e.getMessage());
            }
        }
    }

    public static void init() {
        String traceFile = System.getenv("TLA_TRACE_FILE");
        if (traceFile == null || traceFile.isEmpty()) {
            traceFile = "/tmp/jraft-trace.ndjson";
        }
        init(traceFile);
    }

    /** Reset state (used between test scenarios). */
    public static void reset(String traceFile) {
        synchronized (initLock) {
            close0();
            initialized = false;
            nodeMap.clear();
            nextId.set(1);
            pendingRestarts.clear();
        }
        init(traceFile);
    }

    /** Mark a node as having been crashed; initMetaStorage will emit RestartFromPersisted. */
    public static void markCrashed(String peerIdStr) {
        pendingRestarts.add(nid(peerIdStr));
    }

    /** Returns true if this node should emit RestartFromPersisted on next init (clears the flag). */
    public static boolean consumeRestartPending(String peerIdStr) {
        return pendingRestarts.remove(nid(peerIdStr));
    }

    public static void close() {
        synchronized (initLock) {
            close0();
        }
    }

    private static void close0() {
        writeLock.lock();
        try {
            if (writer != null) {
                writer.flush();
                writer.close();
                writer = null;
            }
        } finally {
            writeLock.unlock();
        }
    }

    /** Map PeerId.toString() to "s1", "s2", "s3" in discovery order. */
    public static String nid(String peerIdStr) {
        if (peerIdStr == null || peerIdStr.isEmpty()) {
            return "nil";
        }
        synchronized (nodeMap) {
            String mapped = nodeMap.get(peerIdStr);
            if (mapped == null) {
                mapped = "s" + nextId.getAndIncrement();
                nodeMap.put(peerIdStr, mapped);
            }
            return mapped;
        }
    }

    /** Pre-register peers in deterministic order so s1/s2/s3 are stable. */
    public static void registerPeers(String... peerIds) {
        synchronized (nodeMap) {
            for (String p : peerIds) {
                if (!nodeMap.containsKey(p)) {
                    nodeMap.put(p, "s" + nextId.getAndIncrement());
                }
            }
        }
    }

    /** Map State enum to TLA+ role string. */
    public static String roleStr(State state) {
        if (state == null) return "Follower";
        switch (state) {
            case STATE_LEADER:    return "Leader";
            case STATE_CANDIDATE: return "Candidate";
            default:              return "Follower";
        }
    }

    /** Map PeerId to persisted-votedFor string ("nil" if empty). */
    public static String persistedVotedForStr(com.alipay.sofa.jraft.entity.PeerId peerId) {
        if (peerId == null || peerId.isEmpty()) {
            return "nil";
        }
        return nid(peerId.toString());
    }

    // =========================================================================
    // Emit helpers
    // =========================================================================

    private static void emit(String json) {
        if (!initialized) return;
        writeLock.lock();
        try {
            if (writer != null) {
                writer.println(json);
                writer.flush();
            }
        } finally {
            writeLock.unlock();
        }
    }

    /** Build a base JSON line with mandatory fields and per-event extras. */
    private static String buildLine(String event, String node, long ts, String extraFields) {
        StringBuilder sb = new StringBuilder(256);
        sb.append("{\"tag\":\"trace\"");
        sb.append(",\"ts\":").append(ts);
        sb.append(",\"event\":\"").append(event).append("\"");
        sb.append(",\"node\":\"").append(node).append("\"");
        if (extraFields != null && !extraFields.isEmpty()) {
            sb.append(",").append(extraFields);
        }
        sb.append("}");
        return sb.toString();
    }

    private static long now() {
        return System.currentTimeMillis();
    }

    // State snapshot helpers

    private static String serverStateFields(long currentTerm, String role) {
        return "\"currentTerm\":" + currentTerm + ",\"role\":\"" + role + "\"";
    }

    private static String persistFields(long persistedTerm, String persistedVotedFor) {
        return "\"persistedTerm\":" + persistedTerm + ",\"persistedVotedFor\":\"" + persistedVotedFor + "\"";
    }

    private static String logStateFields(long lastLogIndex, long commitIndex, long lastApplied) {
        return "\"lastLogIndex\":" + lastLogIndex + ",\"commitIndex\":" + commitIndex + ",\"lastApplied\":" + lastApplied;
    }

    // =========================================================================
    // Event emit methods (called from instrumented source code)
    // =========================================================================

    /**
     * ElectionTimeout: node becomes Candidate, persists (term, self) atomically.
     * Emitted in NodeImpl.electSelf() after setTermAndVotedFor.
     */
    public static void emitElectionTimeout(
            String serverId,
            long currentTerm,
            String role,
            long persistedTerm,
            String persistedVotedFor) {

        String node = nid(serverId);
        String fields = serverStateFields(currentTerm, role)
                + "," + persistFields(persistedTerm, persistedVotedFor);
        emit(buildLine("ElectionTimeout", node, now(), fields));
    }

    /**
     * HandleRequestVoteRequestDeny: reject vote because request.term < currTerm.
     * Emitted before the break in NodeImpl.handleRequestVoteRequest().
     */
    public static void emitRequestVoteDeny(
            String serverId,
            String srcPeerId,
            long currentTerm,
            String role,
            long msgTerm) {

        String node = nid(serverId);
        String src = nid(srcPeerId);
        String fields = serverStateFields(currentTerm, role)
                + ",\"msgTerm\":" + msgTerm
                + ",\"srcNode\":\"" + src + "\""
                + ",\"granted\":false";
        emit(buildLine("HandleRequestVoteRequestDeny", node, now(), fields));
    }

    /**
     * PersistTermEmptyVote (Family 1, Write 1 of 2): after stepDown writes
     * (term, emptyVotedFor) to disk, before setVotedFor(candidateId).
     */
    public static void emitPersistTermEmptyVote(
            String serverId,
            String srcPeerId,
            long currentTerm,
            String role,
            long persistedTerm,
            String persistedVotedFor) {

        String node = nid(serverId);
        String src = nid(srcPeerId);
        String fields = serverStateFields(currentTerm, role)
                + "," + persistFields(persistedTerm, persistedVotedFor)
                + ",\"srcNode\":\"" + src + "\"";
        emit(buildLine("PersistTermEmptyVote", node, now(), fields));
    }

    /**
     * PersistActualVote (Family 1, Write 2 of 2): after setVotedFor(candidateId)
     * in the higher-term grant path.
     */
    public static void emitPersistActualVote(
            String serverId,
            String srcPeerId,
            long persistedTerm,
            String persistedVotedFor) {

        String node = nid(serverId);
        String src = nid(srcPeerId);
        String fields = persistFields(persistedTerm, persistedVotedFor)
                + ",\"srcNode\":\"" + src + "\"";
        emit(buildLine("PersistActualVote", node, now(), fields));
    }

    /**
     * SendVoteGranted (Family 1, Step 3): after response is sent in higher-term path.
     */
    public static void emitSendVoteGranted(
            String serverId,
            String srcPeerId,
            long currentTerm,
            String role,
            long persistedTerm,
            String persistedVotedFor,
            long msgTerm) {

        String node = nid(serverId);
        String src = nid(srcPeerId);
        String fields = serverStateFields(currentTerm, role)
                + "," + persistFields(persistedTerm, persistedVotedFor)
                + ",\"msgTerm\":" + msgTerm
                + ",\"srcNode\":\"" + src + "\""
                + ",\"granted\":true";
        emit(buildLine("SendVoteGranted", node, now(), fields));
    }

    /**
     * HandleRequestVoteRequestGrantSameTerm: same-term grant, single atomic write.
     */
    public static void emitGrantSameTerm(
            String serverId,
            String srcPeerId,
            long currentTerm,
            String role,
            long persistedTerm,
            String persistedVotedFor,
            long msgTerm) {

        String node = nid(serverId);
        String src = nid(srcPeerId);
        String fields = serverStateFields(currentTerm, role)
                + "," + persistFields(persistedTerm, persistedVotedFor)
                + ",\"msgTerm\":" + msgTerm
                + ",\"srcNode\":\"" + src + "\""
                + ",\"granted\":true";
        emit(buildLine("HandleRequestVoteRequestGrantSameTerm", node, now(), fields));
    }

    /**
     * HandleRequestVoteResponse: candidate received a vote response.
     * Emitted after processing in NodeImpl.handleRequestVoteResponse().
     */
    public static void emitHandleVoteResponse(
            String serverId,
            String srcPeerId,
            long currentTerm,
            String role,
            long responseTerm,
            boolean granted) {

        String node = nid(serverId);
        String src = nid(srcPeerId);
        String fields = serverStateFields(currentTerm, role)
                + ",\"msgTerm\":" + responseTerm
                + ",\"srcNode\":\"" + src + "\""
                + ",\"granted\":" + granted;
        emit(buildLine("HandleRequestVoteResponse", node, now(), fields));
    }

    /**
     * Crash: emitted by test harness before shutting down a node.
     * Also marks the node so that initMetaStorage emits RestartFromPersisted on restart.
     */
    public static void emitCrash(
            String serverId,
            long currentTerm,
            String role,
            long persistedTerm,
            String persistedVotedFor) {

        String node = nid(serverId);
        pendingRestarts.add(node);
        String fields = serverStateFields(currentTerm, role)
                + "," + persistFields(persistedTerm, persistedVotedFor);
        emit(buildLine("Crash", node, now(), fields));
    }

    /**
     * RestartFromPersisted: emitted in NodeImpl.initMetaStorage() after loading durable state.
     * Only valid after a Crash event for the same node.
     */
    public static void emitRestartFromPersisted(
            String serverId,
            long currentTerm,
            String role,
            long persistedTerm,
            String persistedVotedFor) {

        String node = nid(serverId);
        String fields = serverStateFields(currentTerm, role)
                + "," + persistFields(persistedTerm, persistedVotedFor);
        emit(buildLine("RestartFromPersisted", node, now(), fields));
    }

    /**
     * ClientRequest: leader appended entry to log.
     * Emitted in NodeImpl.executeApplyingTasks() after logManager.appendEntries().
     */
    public static void emitClientRequest(
            String serverId,
            long lastLogIndex,
            long commitIndex,
            long lastApplied) {

        String node = nid(serverId);
        String fields = logStateFields(lastLogIndex, commitIndex, lastApplied);
        emit(buildLine("ClientRequest", node, now(), fields));
    }

    /**
     * HandleAppendEntriesRequest: follower processed append entries.
     * Emitted in FollowerStableClosure.run() after sendResponse.
     */
    public static void emitHandleAppendEntries(
            String serverId,
            long currentTerm,
            String role,
            long lastLogIndex,
            long commitIndex,
            long lastApplied,
            long lastLeaderContact,
            long prevLogIndex,
            int entriesCount,
            boolean success) {

        String node = nid(serverId);
        String fields = serverStateFields(currentTerm, role)
                + "," + logStateFields(lastLogIndex, commitIndex, lastApplied)
                + ",\"lastLeaderContact\":" + lastLeaderContact
                + ",\"prevLogIndex\":" + prevLogIndex
                + ",\"entriesCount\":" + entriesCount
                + ",\"success\":" + success;
        emit(buildLine("HandleAppendEntriesRequest", node, now(), fields));
    }

    /**
     * HandleInstallSnapshotRequest: follower accepted snapshot metadata.
     * Emitted in NodeImpl.handleInstallSnapshot() before snapshotExecutor.installSnapshot().
     */
    public static void emitHandleInstallSnapshot(
            String serverId,
            long currentTerm,
            String role,
            long snapshotIndex,
            long lastIncludedIndex,
            long lastIncludedTerm,
            long lastLeaderContact) {

        String node = nid(serverId);
        String fields = serverStateFields(currentTerm, role)
                + ",\"snapshotIndex\":" + snapshotIndex
                + ",\"lastIncludedIndex\":" + lastIncludedIndex
                + ",\"lastIncludedTerm\":" + lastIncludedTerm
                + ",\"lastLeaderContact\":" + lastLeaderContact;
        emit(buildLine("HandleInstallSnapshotRequest", node, now(), fields));
    }

    /**
     * HandleInstallSnapshotResponseNormal: leader processed install-snapshot response.
     * Emitted in Replicator.onInstallSnapshotReturned() at end.
     */
    public static void emitHandleInstallSnapshotResponseNormal(
            String serverId,
            long currentTerm,
            String role,
            long responseTerm,
            boolean success) {

        String node = nid(serverId);
        String fields = serverStateFields(currentTerm, role)
                + ",\"responseTerm\":" + responseTerm
                + ",\"success\":" + success;
        emit(buildLine("HandleInstallSnapshotResponseNormal", node, now(), fields));
    }

    /**
     * ServeReadIndex: leader added read request to pendingNotifyStatus.
     * Emitted in NodeImpl.readLeader() after respBuilder.setIndex().
     */
    public static void emitServeReadIndex(
            String serverId,
            long currentTerm,
            String role,
            long readIndex,
            int pendingReadCount) {

        String node = nid(serverId);
        String fields = serverStateFields(currentTerm, role)
                + ",\"readIndex\":" + readIndex
                + ",\"pendingReadCount\":" + pendingReadCount;
        emit(buildLine("ServeReadIndex", node, now(), fields));
    }

    /**
     * ApplyCommittedEntries: FSM applied log entries up to lastApplied.
     * Emitted in FSMCallerImpl.setLastApplied() after notifyLastAppliedIndexUpdated().
     */
    public static void emitApplyCommittedEntries(
            String serverId,
            long lastApplied,
            long commitIndex,
            int pendingReadCount) {

        String node = nid(serverId);
        String fields = "\"lastApplied\":" + lastApplied
                + ",\"commitIndex\":" + commitIndex
                + ",\"pendingReadCount\":" + pendingReadCount;
        emit(buildLine("ApplyCommittedEntries", node, now(), fields));
    }

    /**
     * StepDown: node stepped down from Leader/Candidate to Follower.
     * Emitted in NodeImpl.stepDown() after replicatorGroup.stopAll().
     */
    public static void emitStepDown(
            String serverId,
            long currentTerm,
            String role,
            int pendingReadCount) {

        String node = nid(serverId);
        String fields = serverStateFields(currentTerm, role)
                + ",\"pendingReadCount\":" + pendingReadCount;
        emit(buildLine("StepDown", node, now(), fields));
    }
}
