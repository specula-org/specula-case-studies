----------------------------- MODULE OracleTrace -----------------------------
EXTENDS Trace

(***************************************************************************
Supplementary oracle sensitivity check. It reads observations from real traces
or explicitly labeled mutated copies, without requiring transition equality.
This is NOT implementation correspondence validation. Trace.cfg remains the
canonical full-action/full-post-state validator with all of its invariants.
Only histories needed by the named observational oracles are accumulated here.
***************************************************************************)
OracleInit ==
    LET p==Decode(TraceLog[1].post) IN
    /\ raft=p.raft /\ disk=p.disk /\ ready=p.ready
    /\ application=p.application /\ requests=p.requests /\ wire=p.wire
    /\ history=EmptyHistory /\ quality=EmptyQuality /\ l=2

OracleStep ==
    LET e==TraceLog[l] p==Decode(e.params) post==Decode(e.post)
        h1==IF e.event\in {"ApplyEntry","ApplySnapshot"} THEN
              [history EXCEPT !.applied=@\cup {post.application[p.node].hist}]
            ELSE history
        h2==IF e.event="CompleteRead" THEN
              LET q==post.requests[p.id]
                  rd==post.application[p.node].reads[p.position]
              IN [h1 EXCEPT !.readResults=@\cup
                  {[id |-> p.id, context |-> q.context, rd |-> rd,
                    app |-> post.application[p.node].hist, beforeWrites |-> q.beforeWrites]}]
            ELSE h1
        h3==IF e.event="Advance" THEN
              LET before==raft[p.node] after==post.raft[p.node] b==ready[p.node]
              IN [h2 EXCEPT !.acks=@\cup
                  {[before |-> Hist(before), after |-> Hist(after),
                    oldSnap |-> before.usnap.index, batchSnap |-> b.snapshot.index,
                    afterSnap |-> after.usnap.index, cursor |-> b.cursor, applied |-> after.applied]}]
            ELSE h2
    IN /\ raft'=post.raft /\ disk'=post.disk /\ ready'=post.ready
       /\ application'=post.application /\ requests'=post.requests /\ wire'=post.wire
       /\ history'=h3 /\ quality'=EmptyQuality /\ l'=l+1
OracleNext ==
    \/ /\ l<=Len(TraceLog) /\ OracleStep
    \/ /\ l>Len(TraceLog) /\ UNCHANGED traceVars
OracleSpec == OracleInit /\ [][OracleNext]_traceVars /\ WF_traceVars(OracleNext)
=============================================================================
