-------------------------- MODULE ValidatorBase --------------------------
EXTENDS base
VARIABLE validationHolds
EmptyValidation == [poller |-> 0, id |-> 0, cancelled |-> FALSE]
ValidationInit == validationHolds = [o \in Owners |-> EmptyValidation]
ValidationTypeOK == validationHolds \in [Owners -> [poller : Pollers \cup {0}, id : Nat, cancelled : BOOLEAN]]
ValidationMatch(o,r,p) ==
    /\ validationHolds[o].poller = 0
    /\ \A x \in Owners : validationHolds[x].poller # p
    /\ o \in Owners /\ p \in Pollers /\ r \in owner[o].queued
    /\ owner[o].life \in {"ready","stopping","unload","stopped"} /\ dispatch[p].pc = "idle"
    /\ owner' = [owner EXCEPT ![o].queued = @ \ {r}]
    /\ dispatch' = [dispatch EXCEPT ![p] = [IdleDispatch EXCEPT !.pc = "matched",
          !.owner = o, !.id = r, !.work = catalog[r].work]]
    /\ validationHolds' = [validationHolds EXCEPT ![o] = [poller |-> p, id |-> r, cancelled |-> owner[o].life = "stopped"]]
    /\ UNCHANGED <<durable,catalog,writer,reader,metadata,calls,history,audit>>
ValidationResult(p,result) ==
    /\ p \in Pollers /\ result \in {"valid", "expired", "obsolete"}
    /\ dispatch[p].pc = "matched" /\ Alive(dispatch[p].owner)
    /\ validationHolds[dispatch[p].owner].poller = p
    /\ (result = "obsolete" => ~validationHolds[dispatch[p].owner].cancelled)
    /\ (result = "expired" => history[dispatch[p].work].expired)
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "finish",
          ![p].reply = IF result = "valid" THEN "transient" ELSE result]
    /\ history' = IF result = "obsolete"
          THEN [history EXCEPT ![dispatch[p].work].obsolete = TRUE] ELSE history
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, calls, audit, validationHolds>>
ValidationDone(o) ==
    /\ o \in Owners /\ validationHolds[o].poller # 0
    /\ dispatch[validationHolds[o].poller].pc = "idle"
    /\ validationHolds[o].id \notin owner[o].adding
    /\ validationHolds' = [validationHolds EXCEPT ![o] = EmptyValidation]
    /\ UNCHANGED coreVars
\* A validator owns its poller slot through the actual completion callback.
ValidationCompatible == \A o \in Owners : validationHolds[o].poller # 0 =>
    LET p == validationHolds[o].poller IN
    /\ (dispatch[p].pc = "matched" => dispatch'[p].pc = "matched")
    /\ (dispatch[p].pc = "idle" => dispatch'[p].pc = "idle")
=============================================================================
