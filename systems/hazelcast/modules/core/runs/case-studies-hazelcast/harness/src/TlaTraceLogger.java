package com.hazelcast.cp.internal.raft.impl;

import com.hazelcast.cp.internal.raft.impl.state.RaftState;

import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * TLA+ trace logger for Hazelcast Raft CP Subsystem.
 * Emits NDJSON trace events for trace validation against the TLA+ spec.
 *
 * Thread-safe: all Raft state mutations are serialized per node,
 * but multiple nodes may emit concurrently.
 *
 * Activation: set environment variable RAFT_TRACE_FILE to a file path.
 */
public final class TlaTraceLogger {

    private static volatile BufferedWriter writer;
    private static final ConcurrentHashMap<String, String> ID_MAP = new ConcurrentHashMap<>();
    private static final AtomicInteger NEXT_ID = new AtomicInteger(1);
    private static final Object WRITE_LOCK = new Object();
    private static volatile boolean enabled = false;

    private TlaTraceLogger() { }

    /** Initialize trace logging. Call once at test setup. */
    public static void init(String filePath) {
        if (filePath == null || filePath.isEmpty()) {
            return;
        }
        try {
            synchronized (WRITE_LOCK) {
                if (writer != null) {
                    writer.close();
                }
                writer = new BufferedWriter(new FileWriter(filePath));
                ID_MAP.clear();
                NEXT_ID.set(1);
                enabled = true;
            }
        } catch (IOException e) {
            System.err.println("TlaTraceLogger: failed to open " + filePath + ": " + e);
        }
    }

    /** Shutdown trace logging. Call at test teardown. */
    public static void shutdown() {
        synchronized (WRITE_LOCK) {
            enabled = false;
            if (writer != null) {
                try {
                    writer.flush();
                    writer.close();
                } catch (IOException ignored) { }
                writer = null;
            }
        }
    }

    public static boolean isEnabled() {
        return enabled;
    }

    /** Map implementation endpoint ID to TLA+ short name (s1, s2, ...) */
    public static String mapId(RaftEndpoint endpoint) {
        if (endpoint == null) return "null";
        String raw = endpoint.getUuid().toString();
        return ID_MAP.computeIfAbsent(raw, k -> "s" + NEXT_ID.getAndIncrement());
    }

    /** Capture state snapshot as JSON fragment */
    private static String stateJson(RaftState state) {
        StringBuilder sb = new StringBuilder();
        sb.append("{\"term\":").append(state.term());
        sb.append(",\"role\":\"").append(state.role().name()).append("\"");
        sb.append(",\"commitIndex\":").append(state.commitIndex());
        sb.append(",\"lastLogIndex\":").append(state.log().lastLogOrSnapshotIndex());
        sb.append(",\"lastLogTerm\":").append(state.log().lastLogOrSnapshotTerm());
        String vf = state.votedFor() == null ? "\"none\"" : "\"" + mapId(state.votedFor()) + "\"";
        sb.append(",\"votedFor\":").append(vf);
        sb.append("}");
        return sb.toString();
    }

    /**
     * Emit a node-only event (no message fields).
     * @param event   TLA+ action name (e.g., "Timeout", "ClientRequest")
     * @param node    local endpoint
     * @param state   RaftState snapshot
     * @param extra   additional JSON fields (without leading comma), or null
     */
    public static void emit(String event, RaftEndpoint node, RaftState state, String extra) {
        if (!enabled) return;
        StringBuilder sb = new StringBuilder();
        sb.append("{\"tag\":\"trace\",\"ts\":").append(System.nanoTime());
        sb.append(",\"event\":\"").append(event).append("\"");
        sb.append(",\"node\":\"").append(mapId(node)).append("\"");
        sb.append(",\"state\":").append(stateJson(state));
        if (extra != null) {
            sb.append(",").append(extra);
        }
        sb.append("}");
        writeLine(sb.toString());
    }

    /**
     * Emit a message event (with from/to fields).
     * @param event  TLA+ action name
     * @param node   local endpoint (the handler node)
     * @param from   message source
     * @param to     message destination
     * @param state  RaftState snapshot
     * @param extra  additional JSON fields (without leading comma), or null
     */
    public static void emitMsg(String event, RaftEndpoint node, RaftEndpoint from,
                               RaftEndpoint to, RaftState state, String extra) {
        if (!enabled) return;
        StringBuilder sb = new StringBuilder();
        sb.append("{\"tag\":\"trace\",\"ts\":").append(System.nanoTime());
        sb.append(",\"event\":\"").append(event).append("\"");
        sb.append(",\"node\":\"").append(mapId(node)).append("\"");
        sb.append(",\"from\":\"").append(mapId(from)).append("\"");
        sb.append(",\"to\":\"").append(mapId(to)).append("\"");
        sb.append(",\"state\":").append(stateJson(state));
        if (extra != null) {
            sb.append(",").append(extra);
        }
        sb.append("}");
        writeLine(sb.toString());
    }

    private static void writeLine(String line) {
        synchronized (WRITE_LOCK) {
            if (writer == null) return;
            try {
                writer.write(line);
                writer.newLine();
                writer.flush();
            } catch (IOException e) {
                System.err.println("TlaTraceLogger: write failed: " + e);
            }
        }
    }
}
