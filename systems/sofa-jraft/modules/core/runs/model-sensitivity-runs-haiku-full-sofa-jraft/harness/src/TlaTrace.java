package com.alipay.sofa.jraft.tla;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.locks.ReentrantLock;

/**
 * TLA+ trace emission module for sofa-jraft.
 * Thread-safe NDJSON event writer for protocol action tracing.
 */
public class TlaTrace {
    private static final ObjectMapper mapper = new ObjectMapper();
    private static final ReentrantLock lock = new ReentrantLock();
    private static BufferedWriter writer;
    private static String traceFile = null;
    private static boolean initialized = false;
    private static Map<String, String> nodeIdMap = new HashMap<>();
    private static int nextNodeId = 1;

    /**
     * Initialize trace writer with output file path.
     */
    public static synchronized void init(String outputPath) throws IOException {
        if (initialized) {
            return;
        }
        lock.lock();
        try {
            traceFile = outputPath;
            File f = new File(traceFile);
            f.getParentFile().mkdirs();
            writer = new BufferedWriter(new FileWriter(f));
            initialized = true;

            // Emit config line with timestamp
            ObjectNode config = mapper.createObjectNode();
            config.put("tag", "config");
            config.put("ts", System.nanoTime());
            ObjectNode configData = mapper.createObjectNode();
            configData.put("servers", "dynamic");
            config.set("config", configData);
            writer.write(mapper.writeValueAsString(config));
            writer.newLine();
            writer.flush();
        } finally {
            lock.unlock();
        }
    }

    /**
     * Map implementation node ID to TLA+ name (s1, s2, s3, ...).
     */
    public static String getNodeId(String implId) {
        lock.lock();
        try {
            if (!nodeIdMap.containsKey(implId)) {
                nodeIdMap.put(implId, "s" + (nextNodeId++));
            }
            return nodeIdMap.get(implId);
        } finally {
            lock.unlock();
        }
    }

    /**
     * Emit a trace event.
     */
    public static void emit(String eventName, String nodeId, Map<String, Object> state,
                           Map<String, Object> message) {
        if (!initialized || writer == null) {
            return;
        }
        lock.lock();
        try {
            ObjectNode event = mapper.createObjectNode();
            event.put("tag", "trace");
            event.put("ts", System.nanoTime());

            ObjectNode eventObj = mapper.createObjectNode();
            eventObj.put("name", eventName);
            eventObj.put("nid", nodeId);

            // State fields
            if (state != null) {
                ObjectNode stateObj = mapper.createObjectNode();
                for (Map.Entry<String, Object> entry : state.entrySet()) {
                    Object val = entry.getValue();
                    if (val instanceof Integer) {
                        stateObj.put(entry.getKey(), (Integer) val);
                    } else if (val instanceof Long) {
                        stateObj.put(entry.getKey(), (Long) val);
                    } else if (val instanceof String) {
                        stateObj.put(entry.getKey(), (String) val);
                    } else if (val instanceof Boolean) {
                        stateObj.put(entry.getKey(), (Boolean) val);
                    } else if (val != null) {
                        stateObj.put(entry.getKey(), val.toString());
                    }
                }
                eventObj.set("state", stateObj);
            }

            // Message fields
            if (message != null) {
                ObjectNode msgObj = mapper.createObjectNode();
                for (Map.Entry<String, Object> entry : message.entrySet()) {
                    Object val = entry.getValue();
                    if (val instanceof Integer) {
                        msgObj.put(entry.getKey(), (Integer) val);
                    } else if (val instanceof Long) {
                        msgObj.put(entry.getKey(), (Long) val);
                    } else if (val instanceof String) {
                        msgObj.put(entry.getKey(), (String) val);
                    } else if (val instanceof Boolean) {
                        msgObj.put(entry.getKey(), (Boolean) val);
                    } else if (val != null) {
                        msgObj.put(entry.getKey(), val.toString());
                    }
                }
                eventObj.set("msg", msgObj);
            }

            event.set("event", eventObj);
            writer.write(mapper.writeValueAsString(event));
            writer.newLine();
            writer.flush();
        } catch (IOException e) {
            e.printStackTrace();
        } finally {
            lock.unlock();
        }
    }

    /**
     * Convenience method for state-only events.
     */
    public static void emit(String eventName, String nodeId, Map<String, Object> state) {
        emit(eventName, nodeId, state, null);
    }

    /**
     * Shutdown trace writer.
     */
    public static synchronized void shutdown() {
        lock.lock();
        try {
            if (writer != null) {
                writer.flush();
                writer.close();
                writer = null;
            }
            initialized = false;
        } catch (IOException e) {
            e.printStackTrace();
        } finally {
            lock.unlock();
        }
    }
}
