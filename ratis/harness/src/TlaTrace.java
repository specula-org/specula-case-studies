/*
 * TLA+ trace emission for Apache Ratis trace validation.
 *
 * Emits NDJSON trace events at instrumentation points in the Raft protocol.
 * Activated by setting RATIS_TLA_TRACE environment variable to a file path,
 * or by calling TlaTrace.init(path) explicitly in tests.
 *
 * Thread-safe: all writes are synchronized on a global lock.
 */
package org.apache.ratis.server;

import org.apache.ratis.proto.RaftProtos.RaftPeerRole;
import org.apache.ratis.server.protocol.TermIndex;

import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;

public final class TlaTrace {

    private static volatile BufferedWriter writer;
    private static final Object LOCK = new Object();
    private static volatile boolean autoInitDone = false;

    private TlaTrace() {}

    /** Explicitly initialize with a trace file path. */
    public static void init(String filePath) {
        synchronized (LOCK) {
            close();
            autoInitDone = true;
            if (filePath != null && !filePath.isEmpty()) {
                try {
                    writer = new BufferedWriter(new FileWriter(filePath));
                } catch (IOException e) {
                    System.err.println("TlaTrace: Failed to open " + filePath + ": " + e);
                }
            }
        }
    }

    /** Lazy auto-init from RATIS_TLA_TRACE env var on first use. */
    private static void autoInit() {
        if (!autoInitDone) {
            synchronized (LOCK) {
                if (!autoInitDone) {
                    autoInitDone = true;
                    String envPath = System.getenv("RATIS_TLA_TRACE");
                    if (envPath != null && !envPath.isEmpty()) {
                        try {
                            writer = new BufferedWriter(new FileWriter(envPath));
                        } catch (IOException e) {
                            System.err.println("TlaTrace: Failed to open " + envPath + ": " + e);
                        }
                    }
                }
            }
        }
    }

    public static boolean isEnabled() {
        autoInit();
        return writer != null;
    }

    /**
     * Emit a full trace event from a RaftServer.Division reference.
     * Use this from instrumentation points that have access to the server.
     */
    public static void emit(String event, RaftServer.Division div) {
        emit(event, div, null);
    }

    /**
     * Emit a full trace event with extra JSON fields.
     */
    public static void emit(String event, RaftServer.Division div, String extraJson) {
        if (!isEnabled()) return;
        try {
            String nodeId = div.getId().toString();
            long term = div.getInfo().getCurrentTerm();
            String role = roleStr(div.getInfo().getCurrentRole());
            // Map ratis INVALID_LOG_INDEX (-1) to spec's 0
            long commitIndex = Math.max(0, div.getRaftLog().getLastCommittedIndex());
            TermIndex lastEntry = div.getRaftLog().getLastEntryTermIndex();
            long lastLogIndex = lastEntry != null ? lastEntry.getIndex() : 0;
            long lastLogTerm = lastEntry != null ? lastEntry.getTerm() : 0;
            long flushIndex = Math.max(0, div.getRaftLog().getFlushIndex());
            emitRaw(event, nodeId, term, role, commitIndex, lastLogIndex, lastLogTerm, flushIndex, extraJson);
        } catch (Exception e) {
            // Never let tracing affect the system
        }
    }

    /**
     * Emit a weak trace event (only term + role).
     * Use from contexts without full state access (e.g., LeaderElection).
     */
    public static void emitWeak(String event, String nodeId, long term, String role) {
        emitWeak(event, nodeId, term, role, null);
    }

    public static void emitWeak(String event, String nodeId, long term, String role, String extraJson) {
        if (!isEnabled()) return;
        StringBuilder sb = new StringBuilder(128);
        sb.append("{\"event\":\"").append(event).append("\"");
        sb.append(",\"node\":\"").append(nodeId).append("\"");
        sb.append(",\"term\":").append(term);
        sb.append(",\"role\":\"").append(role).append("\"");
        if (extraJson != null && !extraJson.isEmpty()) {
            sb.append(",").append(extraJson);
        }
        sb.append(",\"ts\":").append(System.nanoTime());
        sb.append("}");
        writeLine(sb.toString());
    }

    private static void emitRaw(String event, String nodeId, long term, String role,
                                long commitIndex, long lastLogIndex, long lastLogTerm,
                                long flushIndex, String extraJson) {
        StringBuilder sb = new StringBuilder(256);
        sb.append("{\"event\":\"").append(event).append("\"");
        sb.append(",\"node\":\"").append(nodeId).append("\"");
        sb.append(",\"term\":").append(term);
        sb.append(",\"role\":\"").append(role).append("\"");
        sb.append(",\"commitIndex\":").append(commitIndex);
        sb.append(",\"lastLogIndex\":").append(lastLogIndex);
        sb.append(",\"lastLogTerm\":").append(lastLogTerm);
        sb.append(",\"flushIndex\":").append(flushIndex);
        if (extraJson != null && !extraJson.isEmpty()) {
            sb.append(",").append(extraJson);
        }
        sb.append(",\"ts\":").append(System.nanoTime());
        sb.append("}");
        writeLine(sb.toString());
    }

    private static void writeLine(String line) {
        synchronized (LOCK) {
            try {
                if (writer != null) {
                    writer.write(line);
                    writer.newLine();
                    writer.flush();
                }
            } catch (IOException e) {
                // silent
            }
        }
    }

    /** Convert RaftPeerRole enum to TLA+ role string. */
    public static String roleStr(RaftPeerRole role) {
        if (role == null) return "FOLLOWER";
        switch (role) {
            case LEADER: return "LEADER";
            case CANDIDATE: return "CANDIDATE";
            default: return "FOLLOWER";
        }
    }

    /** Flush and close the trace file. */
    public static void close() {
        synchronized (LOCK) {
            if (writer != null) {
                try {
                    writer.flush();
                    writer.close();
                } catch (IOException e) {
                    // ignore
                }
                writer = null;
            }
        }
    }

    /** Reset state (for tests). */
    public static void reset() {
        synchronized (LOCK) {
            close();
            autoInitDone = false;
        }
    }
}
