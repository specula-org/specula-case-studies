/*
 * TLA+ Trace Generation Test for Aeron Cluster Election Protocol.
 *
 * Exercises 3 real Election state machines to generate NDJSON traces.
 * Uses mocked infrastructure (Aeron, Archive) but the Election logic
 * is real code — exactly as in production.
 *
 * Each node has its own Election object, mocked context, and candidate term store.
 * Events are driven in protocol order to produce a valid multi-node trace.
 */
package io.aeron.cluster;

import io.aeron.Aeron;
import io.aeron.Counter;
import io.aeron.ExclusivePublication;
import io.aeron.Image;
import io.aeron.Subscription;
import io.aeron.cluster.service.Cluster;
import io.aeron.cluster.service.ClusterMarkFile;
import io.aeron.test.cluster.TestClusterClock;
import org.agrona.collections.Int2ObjectHashMap;
import org.agrona.collections.MutableLong;
import org.agrona.concurrent.CountedErrorHandler;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Random;

import static io.aeron.Aeron.NULL_VALUE;
import static io.aeron.archive.client.AeronArchive.NULL_POSITION;
import static io.aeron.cluster.ConsensusModuleAgent.APPEND_POSITION_FLAG_NONE;
import static java.util.concurrent.TimeUnit.NANOSECONDS;
import static org.mockito.Mockito.*;

class TlaTraceElectionTest
{
    private static final long RECORDING_ID = 600L;
    private static final int LOG_SESSION_ID = 777;
    private static final int VERSION = ConsensusModule.Configuration.PROTOCOL_SEMANTIC_VERSION;

    private final TestClusterClock clock = new TestClusterClock(NANOSECONDS);
    private final Aeron aeron = mock(Aeron.class);
    private final Subscription subscription = mock(Subscription.class);
    private final Image logImage = mock(Image.class);
    private final RecordingLog recordingLog = mock(RecordingLog.class);
    private final ClusterMarkFile clusterMarkFile = mock(ClusterMarkFile.class);
    private final ConsensusPublisher consensusPublisher = mock(ConsensusPublisher.class);
    private final CountedErrorHandler countedErrorHandler = mock(CountedErrorHandler.class);

    // Per-node state
    private final MutableLong[] markFileCandidateTermIds = {
        new MutableLong(-1), new MutableLong(-1), new MutableLong(-1)
    };
    private final NodeStateFile[] nodeStateFiles = new NodeStateFile[3];
    private final NodeStateFile.CandidateTerm[] candidateTerms = new NodeStateFile.CandidateTerm[3];
    private final ConsensusModuleAgent[] agents = new ConsensusModuleAgent[3];
    private final ConsensusModule.Context[] contexts = new ConsensusModule.Context[3];
    private ClusterMember[][] allMembers = new ClusterMember[3][];
    private Election[] elections = new Election[3];

    @BeforeEach
    void setUp()
    {
        when(aeron.addCounter(anyInt(), anyString())).thenReturn(mock(Counter.class));
        when(aeron.addSubscription(anyString(), anyInt())).thenReturn(subscription);
        when(subscription.imageBySessionId(anyInt())).thenReturn(logImage);
        when(recordingLog.isUnknown(anyLong())).thenReturn(Boolean.TRUE);

        TlaTrace.init();
        TlaTrace.registerServers(3);

        for (int n = 0; n < 3; n++)
        {
            nodeStateFiles[n] = mock(NodeStateFile.class);
            candidateTerms[n] = mock(NodeStateFile.CandidateTerm.class);
            agents[n] = mock(ConsensusModuleAgent.class);

            when(nodeStateFiles[n].candidateTerm()).thenReturn(candidateTerms[n]);

            final int nodeIdx = n;
            when(candidateTerms[n].candidateTermId()).thenAnswer(
                inv -> markFileCandidateTermIds[nodeIdx].get());

            when(nodeStateFiles[n].proposeMaxCandidateTermId(anyLong(), anyLong(), anyLong())).thenAnswer(
                inv ->
                {
                    final long c = inv.getArgument(0);
                    final long e = markFileCandidateTermIds[nodeIdx].get();
                    if (c > e) { markFileCandidateTermIds[nodeIdx].set(c); return c; }
                    return e;
                });

            when(agents[n].logRecordingId()).thenReturn(RECORDING_ID);
            when(agents[n].addLogPublication(anyLong())).thenReturn(LOG_SESSION_ID);
            when(agents[n].quorumPositionBoundedByLeaderLog(anyLong(), anyLong())).thenReturn(0L);

            doAnswer(inv ->
            {
                final ClusterMember m = inv.getArgument(0);
                m.leadershipTermId(inv.getArgument(1))
                    .logPosition(inv.getArgument(2))
                    .timeOfLastAppendPositionNs(clock.timeNanos());
                return null;
            }).when(agents[n]).updateMemberLogPosition(any(ClusterMember.class), anyLong(), anyLong());

            contexts[n] = new ConsensusModule.Context()
                .aeron(aeron)
                .recordingLog(recordingLog)
                .clusterClock(clock)
                .epochClock(clock.asEpochClock())
                .random(new Random(42 + n))
                .electionStateCounter(mock(Counter.class))
                .electionCounter(mock(Counter.class))
                .commitPositionCounter(mock(Counter.class))
                .clusterMarkFile(clusterMarkFile)
                .nodeStateFile(nodeStateFiles[n])
                .countedErrorHandler(countedErrorHandler);
        }
    }

    @AfterEach
    void tearDown()
    {
        TlaTrace.close();
    }

    /**
     * Scenario 1: Basic 3-node election.
     *
     * All 3 nodes enter canvass, exchange positions.
     * Node 0 nominates, receives votes, becomes leader.
     * Nodes 1 and 2 accept new leadership term.
     */
    @Test
    void basicElection()
    {
        final long leadershipTermId = NULL_VALUE;
        final long logPosition = 0;
        final long commitPosition = 0;

        // Create elections for all 3 nodes
        for (int n = 0; n < 3; n++)
        {
            allMembers[n] = prepareClusterMembers();
            final Int2ObjectHashMap<ClusterMember> idMap = new Int2ObjectHashMap<>();
            ClusterMember.addClusterMemberIds(allMembers[n], idMap);

            elections[n] = new Election(
                true, NULL_VALUE, leadershipTermId, logPosition, logPosition, logPosition,
                allMembers[n], idMap, allMembers[n][n], consensusPublisher, contexts[n], agents[n]);
        }

        // === Phase 1: All nodes INIT → CANVASS ===
        clock.update(1, clock.timeUnit());
        for (int n = 0; n < 3; n++)
        {
            elections[n].doWork(clock.nanoTime());
            // Emits EnterCanvass for each node
        }

        // === Phase 2: Exchange canvass positions ===
        // Each node sends its position to the others (via publishCanvassPosition in doWork/canvass).
        // Advance time to trigger canvass interval.
        clock.increment(contexts[0].electionStatusIntervalNs() + 1);
        for (int n = 0; n < 3; n++)
        {
            elections[n].doWork(clock.nanoTime());
            // Emits SendCanvassPosition from each node to its peers
        }

        // Each node receives canvass positions from the other two
        for (int n = 0; n < 3; n++)
        {
            for (int j = 0; j < 3; j++)
            {
                if (n != j)
                {
                    elections[n].onCanvassPosition(
                        leadershipTermId, logPosition, leadershipTermId, j, VERSION);
                    // Emits HandleCanvassPosition
                }
            }
        }

        // === Phase 3: Node 0 nominates ===
        // Advance time past election timeout
        clock.increment(contexts[0].electionTimeoutNs());
        elections[0].doWork(clock.nanoTime());
        // canvass() → NOMINATE

        // Advance past nomination delay
        clock.increment(contexts[0].electionTimeoutNs());
        elections[0].doWork(clock.nanoTime());
        // nominate() → CANDIDATE_BALLOT, emits Nominate

        // Send RequestVote to peers
        elections[0].doWork(clock.nanoTime());

        // === Phase 4: Nodes 1,2 vote for node 0 ===
        final long candidateTermIdValue = markFileCandidateTermIds[0].get();

        // Node 1 receives vote request from node 0
        elections[1].onRequestVote(
            leadershipTermId, logPosition, candidateTermIdValue, 0, VERSION);
        // Emits HandleRequestVote (mvote=true)

        // Node 2 receives vote request from node 0
        elections[2].onRequestVote(
            leadershipTermId, logPosition, candidateTermIdValue, 0, VERSION);
        // Emits HandleRequestVote (mvote=true)

        // === Phase 5: Node 0 receives votes ===
        elections[0].onVote(
            leadershipTermId, logPosition, candidateTermIdValue, 0, 1, true);
        // Emits HandleRequestVoteResponse

        elections[0].onVote(
            leadershipTermId, logPosition, candidateTermIdValue, 0, 2, true);
        // Emits HandleRequestVoteResponse

        // === Phase 6: Node 0 becomes leader ===
        clock.increment(1);
        elections[0].doWork(clock.nanoTime());
        // candidateBallot() → isUnanimousLeader → BecomeLeader

        // === Phase 7: Nodes 1,2 receive NewLeadershipTerm ===
        elections[1].onNewLeadershipTerm(
            leadershipTermId,     // logLeadershipTermId
            NULL_VALUE,           // nextLeadershipTermId
            NULL_POSITION,        // nextTermBaseLogPosition
            NULL_POSITION,        // nextLogPosition
            candidateTermIdValue, // leadershipTermId
            logPosition,          // termBaseLogPosition
            logPosition,          // logPosition
            commitPosition,       // commitPosition
            RECORDING_ID,         // leaderRecordingId
            clock.nanoTime(),     // timestamp
            0,                    // leaderMemberId
            LOG_SESSION_ID,       // logSessionId
            true);                // isStartup
        // Emits HandleNewLeadershipTerm for s2

        elections[2].onNewLeadershipTerm(
            leadershipTermId,
            NULL_VALUE,
            NULL_POSITION,
            NULL_POSITION,
            candidateTermIdValue,
            logPosition,
            logPosition,
            commitPosition,
            RECORDING_ID,
            clock.nanoTime(),
            0,
            LOG_SESSION_ID,
            true);
        // Emits HandleNewLeadershipTerm for s3
    }

    /**
     * Scenario 2: Election with commit position exchange.
     *
     * Node 0 becomes leader (abbreviated). Node 1 receives commit position
     * during election phase.
     */
    @Test
    void electionCommitPosition()
    {
        final long leadershipTermId = NULL_VALUE;
        final long logPosition = 0;

        // Create elections for all 3 nodes
        for (int n = 0; n < 3; n++)
        {
            allMembers[n] = prepareClusterMembers();
            final Int2ObjectHashMap<ClusterMember> idMap = new Int2ObjectHashMap<>();
            ClusterMember.addClusterMemberIds(allMembers[n], idMap);

            elections[n] = new Election(
                true, NULL_VALUE, leadershipTermId, logPosition, logPosition, logPosition,
                allMembers[n], idMap, allMembers[n][n], consensusPublisher, contexts[n], agents[n]);
        }

        // All nodes: INIT → CANVASS
        clock.update(1, clock.timeUnit());
        for (int n = 0; n < 3; n++)
        {
            elections[n].doWork(clock.nanoTime());
        }

        // Exchange canvass positions
        clock.increment(contexts[0].electionStatusIntervalNs() + 1);
        for (int n = 0; n < 3; n++)
        {
            elections[n].doWork(clock.nanoTime());
        }
        for (int n = 0; n < 3; n++)
        {
            for (int j = 0; j < 3; j++)
            {
                if (n != j)
                {
                    elections[n].onCanvassPosition(
                        leadershipTermId, logPosition, leadershipTermId, j, VERSION);
                }
            }
        }

        // Node 0 nominates
        clock.increment(contexts[0].electionTimeoutNs());
        elections[0].doWork(clock.nanoTime());
        clock.increment(contexts[0].electionTimeoutNs());
        elections[0].doWork(clock.nanoTime());
        elections[0].doWork(clock.nanoTime());

        final long candidateTermIdValue = markFileCandidateTermIds[0].get();

        // Nodes 1,2 vote
        elections[1].onRequestVote(
            leadershipTermId, logPosition, candidateTermIdValue, 0, VERSION);
        elections[2].onRequestVote(
            leadershipTermId, logPosition, candidateTermIdValue, 0, VERSION);

        elections[0].onVote(
            leadershipTermId, logPosition, candidateTermIdValue, 0, 1, true);
        elections[0].onVote(
            leadershipTermId, logPosition, candidateTermIdValue, 0, 2, true);

        // Node 0 becomes leader
        clock.increment(1);
        elections[0].doWork(clock.nanoTime());

        // Nodes 1,2 receive NLT
        elections[1].onNewLeadershipTerm(
            leadershipTermId, NULL_VALUE, NULL_POSITION, NULL_POSITION,
            candidateTermIdValue, logPosition, logPosition, 42,
            RECORDING_ID, clock.nanoTime(), 0, LOG_SESSION_ID, true);

        elections[2].onNewLeadershipTerm(
            leadershipTermId, NULL_VALUE, NULL_POSITION, NULL_POSITION,
            candidateTermIdValue, logPosition, logPosition, 42,
            RECORDING_ID, clock.nanoTime(), 0, LOG_SESSION_ID, true);

        // Node 1 receives commit position during follower state
        // (onCommitPosition requires leaderMember to be set, which NLT does)
        elections[1].onCommitPosition(candidateTermIdValue, 42, 0);
    }

    private static ClusterMember[] prepareClusterMembers()
    {
        final ClusterMember[] clusterMembers = ClusterMember.parse(
            "0,ingressEndpoint,consensusEndpoint,logEndpoint,catchupEndpoint,archiveEndpoint|" +
            "1,ingressEndpoint,consensusEndpoint,logEndpoint,catchupEndpoint,archiveEndpoint|" +
            "2,ingressEndpoint,consensusEndpoint,logEndpoint,catchupEndpoint,archiveEndpoint|");

        clusterMembers[0].publication(mock(ExclusivePublication.class));
        clusterMembers[1].publication(mock(ExclusivePublication.class));
        clusterMembers[2].publication(mock(ExclusivePublication.class));

        return clusterMembers;
    }
}
