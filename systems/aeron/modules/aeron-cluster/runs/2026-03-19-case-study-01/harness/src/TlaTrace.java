/*
 * TLA+ Trace Emission Module for Aeron Cluster.
 *
 * Emits NDJSON trace events for TLA+ trace validation.
 * Enable via system property: -DtlaTraceFile=path/to/trace.ndjson
 * or environment variable: TLA_TRACE_FILE=path/to/trace.ndjson
 *
 * Thread-safe: uses synchronized writes. Aeron's single-threaded agent model
 * means contention is minimal in practice.
 */
package io.aeron.cluster;

import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

final class TlaTrace
{
    private static volatile BufferedWriter writer;
    private static final AtomicBoolean initialized = new AtomicBoolean(false);
    private static final Map<Integer, String> serverIdMap = new ConcurrentHashMap<>();

    private TlaTrace()
    {
    }

    /**
     * Initialize trace output. Call once at startup.
     * Returns true if tracing is enabled.
     */
    static boolean init()
    {
        if (initialized.compareAndSet(false, true))
        {
            String path = System.getProperty("tlaTraceFile");
            if (null == path)
            {
                path = System.getenv("TLA_TRACE_FILE");
            }
            if (null != path && !path.isEmpty())
            {
                try
                {
                    writer = new BufferedWriter(new FileWriter(path, false));
                    return true;
                }
                catch (final IOException ex)
                {
                    System.err.println("TlaTrace: failed to open " + path + ": " + ex.getMessage());
                }
            }
        }
        return writer != null;
    }

    static boolean isEnabled()
    {
        return writer != null;
    }

    /**
     * Register a server ID mapping. Call for each cluster member.
     * @param memberId  implementation member ID (0, 1, 2, ...)
     * @param tlaName   TLA+ name ("s1", "s2", "s3", ...)
     */
    static void registerServer(final int memberId, final String tlaName)
    {
        serverIdMap.put(memberId, tlaName);
    }

    /**
     * Register servers with default mapping: 0->"s1", 1->"s2", 2->"s3", etc.
     */
    static void registerServers(final int count)
    {
        for (int i = 0; i < count; i++)
        {
            serverIdMap.put(i, "s" + (i + 1));
        }
    }

    static String serverId(final int memberId)
    {
        final String name = serverIdMap.get(memberId);
        return null != name ? name : ("s" + (memberId + 1));
    }

    /**
     * Map implementation term ID to spec term ID.
     * Aeron uses -1 (NULL_VALUE) as initial term; spec uses 0.
     * Mapping: spec_term = impl_term + 1 (so -1→0, 0→1, 1→2, etc.)
     */
    static long mapTerm(final long implTerm)
    {
        return implTerm + 1;
    }

    /**
     * Emit an election event (node-local, no message fields).
     */
    static void emitNodeEvent(
        final String action,
        final int memberId,
        final long candidateTermId,
        final long leadershipTermId,
        final String electionState,
        final long appendPosition,
        final long commitPosition,
        final long notifiedCommitPosition,
        final long nextSessionId)
    {
        if (null == writer)
        {
            return;
        }

        final StringBuilder sb = new StringBuilder(256);
        sb.append("{\"action\":\"").append(action).append('"');
        sb.append(",\"node\":\"").append(serverId(memberId)).append('"');
        sb.append(",\"candidateTermId\":").append(mapTerm(candidateTermId));
        sb.append(",\"leadershipTermId\":").append(mapTerm(leadershipTermId));
        sb.append(",\"electionState\":\"").append(electionState).append('"');
        sb.append(",\"appendPosition\":").append(appendPosition);
        sb.append(",\"commitPosition\":").append(commitPosition);
        sb.append(",\"notifiedCommitPosition\":").append(notifiedCommitPosition);
        sb.append(",\"nextSessionId\":").append(nextSessionId);
        sb.append(",\"ts\":").append(System.nanoTime());
        sb.append('}');
        writeLine(sb.toString());
    }

    /**
     * Emit a message event (between two nodes).
     */
    static void emitMsgEvent(
        final String action,
        final int fromId,
        final int toId,
        final long candidateTermId,
        final long leadershipTermId,
        final String electionState,
        final long appendPosition,
        final long commitPosition,
        final long notifiedCommitPosition,
        final long nextSessionId)
    {
        if (null == writer)
        {
            return;
        }

        final StringBuilder sb = new StringBuilder(256);
        sb.append("{\"action\":\"").append(action).append('"');
        sb.append(",\"node\":\"").append(serverId(toId)).append('"');
        sb.append(",\"from\":\"").append(serverId(fromId)).append('"');
        sb.append(",\"to\":\"").append(serverId(toId)).append('"');
        sb.append(",\"candidateTermId\":").append(mapTerm(candidateTermId));
        sb.append(",\"leadershipTermId\":").append(mapTerm(leadershipTermId));
        sb.append(",\"electionState\":\"").append(electionState).append('"');
        sb.append(",\"appendPosition\":").append(appendPosition);
        sb.append(",\"commitPosition\":").append(commitPosition);
        sb.append(",\"notifiedCommitPosition\":").append(notifiedCommitPosition);
        sb.append(",\"nextSessionId\":").append(nextSessionId);
        sb.append(",\"ts\":").append(System.nanoTime());
        sb.append('}');
        writeLine(sb.toString());
    }

    /**
     * Emit a vote-related message event with vote field.
     */
    static void emitVoteEvent(
        final String action,
        final int fromId,
        final int toId,
        final long candidateTermId,
        final long leadershipTermId,
        final String electionState,
        final boolean vote)
    {
        if (null == writer)
        {
            return;
        }

        final StringBuilder sb = new StringBuilder(256);
        sb.append("{\"action\":\"").append(action).append('"');
        sb.append(",\"node\":\"").append(serverId(toId)).append('"');
        sb.append(",\"from\":\"").append(serverId(fromId)).append('"');
        sb.append(",\"to\":\"").append(serverId(toId)).append('"');
        sb.append(",\"candidateTermId\":").append(mapTerm(candidateTermId));
        sb.append(",\"leadershipTermId\":").append(mapTerm(leadershipTermId));
        sb.append(",\"electionState\":\"").append(electionState).append('"');
        sb.append(",\"mvote\":").append(vote ? "true" : "false");
        sb.append(",\"ts\":").append(System.nanoTime());
        sb.append('}');
        writeLine(sb.toString());
    }

    /**
     * Emit a message event with extra message fields (for canvass/NLT messages).
     */
    static void emitMsgEventWithFields(
        final String action,
        final int fromId,
        final int toId,
        final long candidateTermId,
        final long leadershipTermId,
        final String electionState,
        final long mlogLeadershipTermId,
        final long mlogPosition,
        final long mleadershipTermId)
    {
        if (null == writer)
        {
            return;
        }

        final StringBuilder sb = new StringBuilder(256);
        sb.append("{\"action\":\"").append(action).append('"');
        sb.append(",\"node\":\"").append(serverId(fromId)).append('"');
        sb.append(",\"from\":\"").append(serverId(fromId)).append('"');
        sb.append(",\"to\":\"").append(serverId(toId)).append('"');
        sb.append(",\"candidateTermId\":").append(mapTerm(candidateTermId));
        sb.append(",\"leadershipTermId\":").append(mapTerm(leadershipTermId));
        sb.append(",\"electionState\":\"").append(electionState).append('"');
        sb.append(",\"mlogLeadershipTermId\":").append(mapTerm(mlogLeadershipTermId));
        sb.append(",\"mlogPosition\":").append(mlogPosition);
        sb.append(",\"mleadershipTermId\":").append(mapTerm(mleadershipTermId));
        sb.append(",\"ts\":").append(System.nanoTime());
        sb.append('}');
        writeLine(sb.toString());
    }

    /**
     * Emit a commit position message event.
     */
    static void emitCommitPositionEvent(
        final String action,
        final int fromId,
        final int toId,
        final long mcommitPosition,
        final long notifiedCommitPosition,
        final long commitPosition,
        final long nextSessionId,
        final String electionState)
    {
        if (null == writer)
        {
            return;
        }

        final StringBuilder sb = new StringBuilder(256);
        sb.append("{\"action\":\"").append(action).append('"');
        sb.append(",\"node\":\"").append(serverId(toId)).append('"');
        sb.append(",\"from\":\"").append(serverId(fromId)).append('"');
        sb.append(",\"to\":\"").append(serverId(toId)).append('"');
        sb.append(",\"mcommitPosition\":").append(mcommitPosition);
        sb.append(",\"notifiedCommitPosition\":").append(notifiedCommitPosition);
        sb.append(",\"commitPosition\":").append(commitPosition);
        sb.append(",\"nextSessionId\":").append(nextSessionId);
        sb.append(",\"electionState\":\"").append(electionState).append('"');
        sb.append(",\"ts\":").append(System.nanoTime());
        sb.append('}');
        writeLine(sb.toString());
    }

    /**
     * Emit a simple node event with minimal fields (e.g., Crash, Timeout).
     */
    static void emitSimpleEvent(final String action, final int memberId, final String electionState)
    {
        if (null == writer)
        {
            return;
        }

        final StringBuilder sb = new StringBuilder(128);
        sb.append("{\"action\":\"").append(action).append('"');
        sb.append(",\"node\":\"").append(serverId(memberId)).append('"');
        sb.append(",\"electionState\":\"").append(electionState).append('"');
        sb.append(",\"ts\":").append(System.nanoTime());
        sb.append('}');
        writeLine(sb.toString());
    }

    static void close()
    {
        final BufferedWriter w = writer;
        if (null != w)
        {
            try
            {
                w.flush();
                w.close();
            }
            catch (final IOException ignore)
            {
                // best effort
            }
            writer = null;
        }
        initialized.set(false);
        serverIdMap.clear();
    }

    private static synchronized void writeLine(final String line)
    {
        final BufferedWriter w = writer;
        if (null != w)
        {
            try
            {
                w.write(line);
                w.newLine();
                w.flush();
            }
            catch (final IOException ex)
            {
                System.err.println("TlaTrace: write failed: " + ex.getMessage());
            }
        }
    }
}
