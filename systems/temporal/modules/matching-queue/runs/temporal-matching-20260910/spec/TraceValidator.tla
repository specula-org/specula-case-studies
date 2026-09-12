-------------------------- MODULE TraceValidator --------------------------
EXTENDS Trace, ValidatorBase
V == INSTANCE ValidatorBase
vtracevars == <<tracevars, validationHolds>>
ValidateValidationPost(e,keys) ==
    /\ DOMAIN e.post = keys
    /\ \A k \in keys \ {"validationHolds"} :
         EncodingOK(e.post,k) /\ DecodeGroup(e.post,k) = ModelGroup(k)'
    /\ ("validationHolds" \in keys => e.post.validationHolds = validationHolds')
TraceValidationMatch(e) ==
    /\ Envelope(e,"ValidationMatch",e.args.o,{"o","r","p"})
    /\ Track(V!ValidationMatch(e.args.o,e.args.r,e.args.p))
    /\ ValidateValidationPost(e,{"owner","dispatch","validationHolds"})
    /\ l' = l + 1
TraceValidationResult(e) ==
    /\ Envelope(e,"ValidationResult",dispatch[e.args.p].owner,{"p","result"})
    /\ Track(V!ValidationResult(e.args.p,e.args.result))
    /\ ValidateValidationPost(e,{"dispatch","history"})
    /\ l' = l + 1
TraceValidationDone(e) ==
    /\ Envelope(e,"ValidationDone",e.args.o,{"o"})
    /\ Track(V!ValidationDone(e.args.o))
    /\ ValidateValidationPost(e,{"validationHolds"})
    /\ l' = l + 1
ValidationTraceEnd(e) ==
    /\ DOMAIN e.post = AllKeys \cup {"validationHolds"}
    /\ TraceEnd([e EXCEPT !.post = [k \in AllKeys |-> e.post[k]]])
    /\ UNCHANGED validationHolds
    /\ e.post.validationHolds = validationHolds
    /\ \A o \in Owners : validationHolds[o] = EmptyValidation
ValidationTraceInit == TraceInit /\ ValidationInit
ValidationTraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ LET e == TraceLog[l] IN
          CASE e.event = "ValidationMatch" -> TraceValidationMatch(e)
            [] e.event = "ValidationResult" -> TraceValidationResult(e)
            [] e.event = "ValidationDone" -> TraceValidationDone(e)
            [] e.event = "TraceEnd" -> ValidationTraceEnd(e)
            [] OTHER -> MatchEvent(e) /\ UNCHANGED validationHolds
    \/ /\ l > Len(TraceLog) /\ UNCHANGED vtracevars
ValidationTraceSpec == ValidationTraceInit /\ [][ValidationTraceNext]_vtracevars
                       /\ WF_vtracevars(ValidationTraceNext)
=============================================================================
