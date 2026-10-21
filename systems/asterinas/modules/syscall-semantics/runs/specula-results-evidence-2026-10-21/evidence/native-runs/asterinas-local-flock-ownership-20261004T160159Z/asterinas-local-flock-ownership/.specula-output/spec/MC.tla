------------------------------- MODULE MC -------------------------------
EXTENDS base
B == INSTANCE base
CONSTANTS Fixture, T1, T2, T3, A, Bof, C,
          MaxOpen, MaxDup, MaxClose, MaxFlock
ASSUME /\ Threads = {T1, T2, T3} /\ OFDs = {A, Bof, C}
       /\ MaxFlock <= Cardinality(Tokens)
VARIABLES admitted, issued, completed, observed, linuxMode, linuxResult
mcVars == <<admitted, issued, completed, observed, linuxMode, linuxResult>>
allVars == <<vars, mcVars>>

(* Only environment admissions are bounded. No fault, preemption, weakened
   wake, artificial timeout or recursive-lock failure is injected. All reactive
   steps, including scans, Arc puts, notifications and retries, remain enabled.
   The fixture programs are the finite caller schedules in brief section 2 and
   contracts C01-C12. Gates observe real modeled registration/reference windows.
   They are harness scheduling obligations, not kernel API guarantees. *)
Need(x, y, z) == [t \in Threads |-> IF t = T1 THEN x ELSE IF t = T2 THEN y ELSE z]
Op(k, f, o, m, nb, n, g) ==
    [kind |-> k, fd |-> f, ofd |-> o, mode |-> m, nb |-> nb, need |-> n, gate |-> g]
OpenOp(o, n) == Op("open", Nil, o, "UN", FALSE, n, "none")
DupOp(f, n) == Op("dup", f, Nil, "UN", FALSE, n, "none")
CloseOp(f, n, g) == Op("close", f, Nil, "UN", FALSE, n, g)
FlockOp(f, m, nb, n, g) == Op("flock", f, Nil, m, nb, n, g)

Plan(t) ==
    CASE Fixture = "c01" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "SH", TRUE, Need(0, 0, 0), "none"),
                FlockOp(1, "UN", TRUE, Need(0, 0, 2), "none")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "SH", TRUE, Need(0, 0, 0), "none"),
                FlockOp(2, "UN", TRUE, Need(0, 0, 2), "none")>>
           ELSE <<OpenOp(C, Need(0, 1, 0)),
                FlockOp(3, "EX", TRUE, Need(2, 2, 0), "none"),
                FlockOp(3, "EX", TRUE, Need(3, 3, 0), "none")>>
      [] Fixture = "c02" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "EX", TRUE, Need(0, 0, 0), "none"),
                DupOp(1, Need(0, 0, 0)),
                FlockOp(2, "EX", TRUE, Need(0, 0, 0), "none"),
                FlockOp(2, "UN", TRUE, Need(0, 0, 0), "none"),
                FlockOp(2, "UN", TRUE, Need(0, 0, 0), "none")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(3, 0, 0)),
                FlockOp(3, "EX", TRUE, Need(5, 0, 0), "none"),
                FlockOp(3, "UN", TRUE, Need(0, 0, 0), "none")>>
           ELSE <<>>
      [] Fixture = "reuse" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "EX", TRUE, Need(0, 0, 0), "none"),
                CloseOp(1, Need(0, 0, 0), "captured2A"),
                OpenOp(Bof, Need(0, 0, 0))>>
           ELSE IF t = T2 THEN <<FlockOp(1, "SH", FALSE, Need(2, 0, 0), "none")>>
           ELSE <<>>
      [] Fixture = "c03" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "EX", TRUE, Need(0, 0, 0), "none"),
                DupOp(1, Need(0, 0, 0)),
                CloseOp(1, Need(0, 1, 0), "none"),
                CloseOp(2, Need(0, 2, 0), "none")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(3, 0, 0)),
                FlockOp(3, "EX", TRUE, Need(4, 0, 0), "none"),
                FlockOp(3, "EX", TRUE, Need(5, 0, 0), "none")>>
           ELSE <<>>
      [] Fixture = "c04" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "SH", TRUE, Need(0, 0, 0), "none"),
                FlockOp(1, "EX", TRUE, Need(0, 0, 0), "none"),
                FlockOp(1, "SH", TRUE, Need(0, 0, 0), "reg2A"),
                FlockOp(1, "UN", TRUE, Need(0, 2, 0), "none")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "SH", FALSE, Need(3, 0, 0), "none"),
                FlockOp(2, "UN", TRUE, Need(0, 0, 0), "none")>>
           ELSE <<>>
      [] Fixture = "c05" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "SH", TRUE, Need(0, 0, 0), "none"),
                FlockOp(1, "EX", TRUE, Need(0, 2, 0), "none")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "SH", TRUE, Need(0, 0, 0), "none"),
                FlockOp(2, "UN", TRUE, Need(3, 0, 0), "none")>>
           ELSE <<OpenOp(C, Need(0, 1, 0)),
                FlockOp(3, "EX", TRUE, Need(3, 3, 0), "none")>>
      [] Fixture = "c06" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "SH", TRUE, Need(0, 0, 0), "none"),
                FlockOp(1, "EX", FALSE, Need(0, 2, 0), "none"),
                FlockOp(1, "UN", TRUE, Need(0, 0, 0), "none")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "SH", TRUE, Need(0, 0, 0), "none"),
                FlockOp(2, "EX", FALSE, Need(2, 0, 0), "reg1B"),
                FlockOp(2, "UN", TRUE, Need(0, 0, 0), "none")>>
           ELSE <<>>
      [] Fixture = "c07_before" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "EX", TRUE, Need(0, 0, 0), "none"),
                FlockOp(1, "UN", TRUE, Need(0, 1, 0), "none")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "EX", FALSE, Need(3, 0, 0), "none"),
                FlockOp(2, "UN", TRUE, Need(0, 0, 0), "none")>>
           ELSE <<>>
      [] Fixture = "c07_after" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "EX", TRUE, Need(0, 0, 0), "none"),
                FlockOp(1, "UN", TRUE, Need(0, 0, 0), "reg2A")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "EX", FALSE, Need(2, 0, 0), "none"),
                FlockOp(2, "UN", TRUE, Need(0, 0, 0), "none")>>
           ELSE <<>>
      [] Fixture = "c08" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "SH", TRUE, Need(0, 0, 0), "none"),
                FlockOp(1, "UN", TRUE, Need(0, 0, 0), "reg3A")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "SH", TRUE, Need(2, 0, 0), "none"),
                FlockOp(2, "UN", TRUE, Need(3, 0, 0), "reg3B")>>
           ELSE <<OpenOp(C, Need(0, 1, 0)),
                FlockOp(3, "EX", FALSE, Need(2, 2, 0), "none"),
                FlockOp(3, "UN", TRUE, Need(0, 0, 0), "none")>>
      [] Fixture = "c09" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "EX", TRUE, Need(0, 0, 0), "none"),
                FlockOp(1, "UN", TRUE, Need(0, 0, 0), "both23A")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "EX", FALSE, Need(2, 0, 0), "none"),
                FlockOp(2, "UN", TRUE, Need(0, 0, 0), "none")>>
           ELSE <<OpenOp(C, Need(0, 1, 0)),
                FlockOp(3, "EX", FALSE, Need(2, 0, 0), "none"),
                FlockOp(3, "UN", TRUE, Need(0, 0, 0), "none")>>
      [] Fixture = "c10" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "EX", TRUE, Need(0, 0, 0), "none"),
                FlockOp(1, "UN", TRUE, Need(0, 0, 1), "none")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "EX", FALSE, Need(2, 0, 0), "none")>>
           ELSE <<CloseOp(2, Need(2, 1, 0), "reg2A"),
                OpenOp(C, Need(0, 2, 0)),
                FlockOp(2, "EX", TRUE, Need(0, 0, 0), "none")>>
      [] Fixture = "c11" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "UN", TRUE, Need(0, 2, 0), "none")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "SH", TRUE, Need(0, 0, 0), "none"),
                CloseOp(2, Need(0, 0, 0), "temp1B")>>
           ELSE <<>>
      [] Fixture = "c12_alias" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "UN", TRUE, Need(0, 3, 0), "none")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "SH", TRUE, Need(0, 0, 0), "none"),
                DupOp(2, Need(0, 0, 0)),
                CloseOp(2, Need(0, 0, 0), "temp1B"),
                CloseOp(3, Need(2, 0, 0), "none")>>
           ELSE <<>>
      [] Fixture = "c12_before" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "UN", TRUE, Need(0, 3, 0), "none")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "SH", TRUE, Need(0, 0, 0), "none"),
                CloseOp(2, Need(0, 0, 0), "none")>>
           ELSE <<>>
      [] Fixture = "c12_after" ->
           IF t = T1 THEN <<OpenOp(A, Need(0, 0, 0)),
                FlockOp(1, "UN", TRUE, Need(0, 2, 0), "none")>>
           ELSE IF t = T2 THEN <<OpenOp(Bof, Need(1, 0, 0)),
                FlockOp(2, "SH", TRUE, Need(0, 0, 0), "none"),
                CloseOp(2, Need(2, 0, 0), "none")>>
           ELSE <<>>
      [] OTHER -> <<>>

\* flock.rs:116-118. Observe actual queue membership, not a userspace ready flag.
RegisteredOn(t, o) ==
    /\ s.th[t].rid /= Nil
    /\ \E i \in 1..Len(s.items) :
        /\ s.items[i].owner = o
        /\ QueueHas(s.items[i].q, s.th[t].rid)
Gate(g) ==
    CASE g = "none" -> TRUE
      [] g = "reg1B" -> RegisteredOn(T1, Bof)
      [] g = "reg2A" -> RegisteredOn(T2, A)
      [] g = "reg3A" -> RegisteredOn(T3, A)
      [] g = "reg3B" -> RegisteredOn(T3, Bof)
      [] g = "both23A" -> RegisteredOn(T2, A) /\ RegisteredOn(T3, A)
      [] g = "temp1B" -> s.th[T1].temp = Bof
      [] g = "captured2A" -> s.th[T2].request = A /\ s.th[T2].callRef
      [] OTHER -> FALSE
Permit(t, k, f, o, m, nb) ==
    IF Fixture = "general" THEN TRUE
    ELSE /\ issued[t] < Len(Plan(t))
         /\ LET p == Plan(t)[issued[t] + 1]
            IN /\ p.kind = k /\ p.fd = f /\ p.ofd = o
               /\ p.mode = m /\ p.nb = nb /\ Gate(p.gate)
               /\ \A u \in Threads : completed[u] >= p.need[u]

\* Linux v6.16.5 4645fefac0b24d509b962c096b0327e87f34b1d2,
\* fs/locks.c:1096-1137. This oracle is used ONLY for the sequential C05
\* comparison. Delete, conflict check and insert are one spinlock operation.
LinuxStep(lm, o, m) ==
    LET cleared == IF lm[o] = m THEN lm ELSE [lm EXCEPT ![o] = "UN"]
        conflict == \E b \in OFDs \ {o} :
                       cleared[b] /= "UN" /\ (cleared[b] = "EX" \/ m = "EX")
    IN IF m = "UN" THEN [mode |-> cleared, result |-> "OK"]
       ELSE IF lm[o] = m THEN [mode |-> lm, result |-> "OK"]
       ELSE IF conflict THEN [mode |-> cleared, result |-> "EAGAIN"]
       ELSE [mode |-> [cleared EXCEPT ![o] = m], result |-> "OK"]

MCInit ==
    /\ B!Init
    /\ admitted = [open |-> 0, dup |-> 0, close |-> 0, flock |-> 0]
    /\ issued = [t \in Threads |-> 0] /\ completed = [t \in Threads |-> 0]
    /\ observed = [t \in Threads |-> "NONE"]
    /\ linuxMode = [o \in OFDs |-> "UN"]
    /\ linuxResult = [t \in Threads |-> "NONE"]

\* Each bound is checked and incremented on the admission itself. Completed
\* syscalls and every deterministic follow-up remain outside these bounds.
MCOpen(t, o) ==
    /\ admitted.open < MaxOpen /\ Permit(t, "open", Nil, o, "UN", FALSE)
    /\ B!SysOpen(t, o)
    /\ admitted' = [admitted EXCEPT !.open = @ + 1]
    /\ issued' = [issued EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<completed, observed, linuxMode, linuxResult>>
MCDup(t, f, g) ==
    /\ admitted.dup < MaxDup /\ Permit(t, "dup", f, Nil, "UN", FALSE)
    /\ B!SysDup(t, f, g)
    /\ admitted' = [admitted EXCEPT !.dup = @ + 1]
    /\ issued' = [issued EXCEPT ![t] = @ + 1]
    /\ completed' = [completed EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<observed, linuxMode, linuxResult>>
MCClose(t, f) ==
    /\ admitted.close < MaxClose /\ Permit(t, "close", f, Nil, "UN", FALSE)
    /\ B!SysClose(t, f)
    /\ admitted' = [admitted EXCEPT !.close = @ + 1]
    /\ issued' = [issued EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<completed, observed, linuxMode, linuxResult>>
MCFlock(t, f, m, nb) ==
    /\ admitted.flock < MaxFlock /\ Permit(t, "flock", f, Nil, m, nb)
    /\ B!SysFlock(t, f, m, nb)
    /\ admitted' = [admitted EXCEPT !.flock = @ + 1]
    /\ issued' = [issued EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<completed, observed, linuxMode, linuxResult>>
Admission(t) ==
    \/ \E o \in OFDs : MCOpen(t, o)
    \/ \E f, g \in FDs : MCDup(t, f, g)
    \/ \E f \in FDs : MCClose(t, f)
    \/ \E f \in FDs, m \in Modes, nb \in BOOLEAN : MCFlock(t, f, m, nb)

\* Fresh token names have no semantic order. Pick a canonical one in MC
\* only. The base and Trace modules accept every supplied fresh identity.
BaseReaction(t) ==
    IF s.th[t].pc = "dispatch" /\ s.th[t].mode /= "UN"
    THEN \E q \in Tokens \ s.used :
            /\ \A r \in Tokens \ s.used : q <= r
            /\ B!FlockItemNew(t, q)
    ELSE B!ThreadStep(t)
Reaction(t) ==
    /\ BaseReaction(t)
    /\ UNCHANGED <<admitted, issued>>
    /\ completed' = IF s'.last \in {"SysOpenReturn", "SysCloseReturn",
                                     "SysFlockReturn"}
                    THEN [completed EXCEPT ![t] = @ + 1] ELSE completed
    /\ IF s'.last = "SysFlockReturn"
       THEN /\ observed' = [observed EXCEPT ![t] = s.th[t].result]
            /\ IF Fixture = "c05"
               THEN LET l == LinuxStep(linuxMode, s.th[t].captured, s.th[t].mode)
                    IN /\ linuxMode' = l.mode
                       /\ linuxResult' = [linuxResult EXCEPT ![t] = l.result]
               ELSE UNCHANGED <<linuxMode, linuxResult>>
       ELSE UNCHANGED <<observed, linuxMode, linuxResult>>
MCNext == \E t \in Threads : Admission(t) \/ Reaction(t)
MCSpec == MCInit /\ [][MCNext]_allVars
\* These fairness assumptions apply only to the closed finite fixtures.
\* They give execution opportunities and promised admissions, never a grant.
FairMCSpec == MCSpec /\ \A t \in Threads :
    WF_allVars(Reaction(t)) /\ WF_allVars(Admission(t))
MCSymmetry == Permutations(Threads)
\* Keep counters in the fingerprint. They affect future enabled admissions.
MCTypeOK == TypeOK /\ \A t \in Threads :
    /\ completed[t] <= issued[t] /\ completed[t] \in Nat /\ issued[t] \in Nat
FixtureCompletes == <>(\A t \in Threads : completed[t] = Len(Plan(t)))
\* Check each return before observed can be overwritten by another operation.
\* C01's first C probe and C03's first B probe must fail. All other returns
\* in these controls succeed, including C02's repeated/unmatched unlocks.
ControlResults == s.last = "SysFlockReturn" =>
    LET t == s.actor
    IN CASE Fixture = "c01" ->
                observed[t] = IF t = T3 /\ completed[t] = 2
                              THEN "EAGAIN" ELSE "OK"
         [] Fixture = "c03" ->
                observed[t] = IF t = T2 /\ completed[t] = 2
                              THEN "EAGAIN" ELSE "OK"
         [] Fixture \in {"c02", "c10"} -> observed[t] = "OK"
         [] OTHER -> TRUE
ConvertersDrain == (Fixture = "c06") => FixtureCompletes
ConversionOracle == (Fixture = "c05" /\ completed[T3] = Len(Plan(T3)))
                    => observed[T3] = linuxResult[T3]
=============================================================================
