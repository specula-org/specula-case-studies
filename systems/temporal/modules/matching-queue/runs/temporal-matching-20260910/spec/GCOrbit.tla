---------------------------- MODULE GCOrbit ----------------------------
EXTENDS GCOrdered
ASSUME Pollers = {1,2} /\ Work = {w1,w2}
P(pi,p) == IF p = 0 THEN 0 ELSE pi[p]
NonceRefs(pi) == <<history[w1].start, history[w2].start,
    IF dispatch[pi[1]].pc = "idle" THEN 0 ELSE dispatch[pi[1]].request,
    IF dispatch[pi[2]].pc = "idle" THEN 0 ELSE dispatch[pi[2]].request>>
Q(pi,q) == IF q = 0 THEN 0 ELSE
    LET refs == NonceRefs(pi)
        first == CHOOSE i \in 1..4 : refs[i] = q /\ (\A j \in 1..(i-1) : refs[j] # q)
    IN Cardinality({refs[i] : i \in {j \in 1..first : refs[j] # 0}})
RenamedKey(pi) ==
    LET k == ContractView IN
    [k EXCEPT
      ![3] = [o \in Owners |-> [k[3][o] EXCEPT
          !.cachePoller = P(pi,k[3][o].cachePoller),
          !.appendQueue = [i \in 1..Len(k[3][o].appendQueue) |->
              [k[3][o].appendQueue[i] EXCEPT !.poller = P(pi,k[3][o].appendQueue[i].poller)]]]],
      ![4] = [o \in Owners |-> [k[4][o] EXCEPT !.poller = P(pi,k[4][o].poller)]],
      ![7] = [p \in Pollers |-> [k[7][pi[p]] EXCEPT !.request = Q(pi,k[7][pi[p]].request)]],
      ![9] = [w \in Work |-> [history[w] EXCEPT !.start = Q(pi,history[w].start)]]]
\* Role-specific alpha equivalence: record IDs, work, owners and causal stages stay fixed.
GCOrbitView == <<{RenamedKey(pi) : pi \in Permutations(Pollers)},stage>>
=============================================================================
