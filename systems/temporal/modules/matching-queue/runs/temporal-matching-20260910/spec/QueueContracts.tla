------------------------- MODULE QueueContracts -------------------------
EXTENDS Integers, FiniteSets, TLC
CONSTANTS Work, Block, Mutant
O == {1,2}
Ids == 1..(2*Block)
VARIABLES rows, catalog, committed, required, discharged, durableRange, durableAck,
          ownerRange, ready, nextId, maxRead, ack, write, meta, gc, badDelete, badFence
vars == <<rows,catalog,committed,required,discharged,durableRange,durableAck,
          ownerRange,ready,nextId,maxRead,ack,write,meta,gc,badDelete,badFence>>
IdleWrite == [pc |-> "idle", id |-> 0]
IdleMeta == [pc |-> "idle", kind |-> "none", expect |-> 0, nextRange |-> 0, ack |-> 0, ok |-> FALSE]
Max(a,b) == IF a>b THEN a ELSE b
First(s,n) == {i \in s : Cardinality({j \in s : j<i}) < n}
Covered(w,rs,b) == w \in discharged \/ (\E r \in rs : catalog[r]=w /\ r>b)
PrefixSound(b) == \A r \in committed : r<=b => Covered(catalog[r],rows,b)
Init ==
    /\ rows={} /\ committed={} /\ required={} /\ discharged={}
    /\ catalog=[r \in Ids |-> 0]
    /\ durableRange=1 /\ durableAck=0
    /\ ownerRange=[o \in O |-> IF o=1 THEN 1 ELSE 0]
    /\ ready=[o \in O |-> o=1]
    /\ nextId=[o \in O |-> 1]
    /\ maxRead=[o \in O |-> 0] /\ ack=[o \in O |-> 0]
    /\ write=[o \in O |-> IdleWrite] /\ meta=[o \in O |-> IdleMeta]
    /\ gc=[o \in O |-> -1] /\ badDelete=FALSE /\ badFence=FALSE
Reserve(o,w) ==
    /\ ready[o] /\ write[o].pc="idle" /\ meta[o].pc="idle"
    /\ nextId[o]<=ownerRange[o]*Block /\ catalog[nextId[o]]=0
    /\ catalog'=[catalog EXCEPT ![nextId[o]]=w]
    /\ write'=[write EXCEPT ![o]=[pc |-> "store",id |-> nextId[o]]]
    /\ nextId'=[nextId EXCEPT ![o]=@+1]
    /\ UNCHANGED <<rows,committed,required,discharged,durableRange,durableAck,ownerRange,ready,maxRead,ack,meta,gc,badDelete,badFence>>
CommitWrite(o) ==
    /\ write[o].pc="store" /\ (ownerRange[o]=durableRange \/ Mutant="unfenced")
    /\ rows'=rows \cup {write[o].id} /\ committed'=committed \cup {write[o].id}
    /\ required'=required \cup {catalog[write[o].id]}
    /\ write'=[write EXCEPT ![o].pc="return"]
    /\ badFence'=(badFence \/ ownerRange[o]#durableRange)
    /\ UNCHANGED <<catalog,discharged,durableRange,durableAck,ownerRange,ready,nextId,maxRead,ack,meta,gc,badDelete>>
RejectWrite(o) ==
    /\ write[o].pc="store" /\ write'=[write EXCEPT ![o].pc="return"]
    /\ UNCHANGED <<rows,catalog,committed,required,discharged,durableRange,durableAck,ownerRange,ready,nextId,maxRead,ack,meta,gc,badDelete,badFence>>
ReturnWrite(o) ==
    /\ write[o].pc="return"
    /\ maxRead'=[maxRead EXCEPT ![o]=Max(@,write[o].id)]
    /\ write'=[write EXCEPT ![o]=IdleWrite]
    /\ UNCHANGED <<rows,catalog,committed,required,discharged,durableRange,durableAck,ownerRange,ready,nextId,ack,meta,gc,badDelete,badFence>>
Discharge(w) ==
    /\ w \in required \ discharged /\ discharged'=discharged \cup {w}
    /\ UNCHANGED <<rows,catalog,committed,required,durableRange,durableAck,ownerRange,ready,nextId,maxRead,ack,write,meta,gc,badDelete,badFence>>
\* Assumption discharged by the detailed reader/completion checks, not proved here.
\* maxRead is advertised only after write outcome resolution, or closes a fenced old block.
AdvanceAck(o,b) ==
    /\ ready[o] /\ write[o].pc="idle" /\ meta[o].pc="idle"
    /\ b>ack[o] /\ b<=maxRead[o] /\ PrefixSound(b)
    /\ ack'=[ack EXCEPT ![o]=b]
    /\ UNCHANGED <<rows,catalog,committed,required,discharged,durableRange,durableAck,ownerRange,ready,nextId,maxRead,write,meta,gc,badDelete,badFence>>
CaptureSync(o,b) ==
    /\ ready[o] /\ write[o].pc="idle" /\ meta[o].pc="idle" /\ b<=ack[o]
    /\ meta'=[meta EXCEPT ![o]=[pc |-> "store",kind |-> "sync",expect |-> ownerRange[o],nextRange |-> ownerRange[o],ack |-> b,ok |-> FALSE]]
    /\ UNCHANGED <<rows,catalog,committed,required,discharged,durableRange,durableAck,ownerRange,ready,nextId,maxRead,ack,write,gc,badDelete,badFence>>
CaptureTakeover ==
    /\ ~ready[2] /\ meta[2].pc="idle" /\ durableRange=1
    /\ meta'=[meta EXCEPT ![2]=[pc |-> "store",kind |-> "take",expect |-> durableRange,nextRange |-> 2,ack |-> durableAck,ok |-> FALSE]]
    /\ UNCHANGED <<rows,catalog,committed,required,discharged,durableRange,durableAck,ownerRange,ready,nextId,maxRead,ack,write,gc,badDelete,badFence>>
CommitMetadata(o) ==
    /\ meta[o].pc="store" /\ meta[o].expect=durableRange
    /\ durableRange'=meta[o].nextRange /\ durableAck'=meta[o].ack
    /\ meta'=[meta EXCEPT ![o].pc="return",![o].ok=TRUE]
    /\ UNCHANGED <<rows,catalog,committed,required,discharged,ownerRange,ready,nextId,maxRead,ack,write,gc,badDelete,badFence>>
RejectMetadata(o) ==
    /\ meta[o].pc="store" /\ meta'=[meta EXCEPT ![o].pc="return"]
    /\ UNCHANGED <<rows,catalog,committed,required,discharged,durableRange,durableAck,ownerRange,ready,nextId,maxRead,ack,write,gc,badDelete,badFence>>
ReturnMetadata(o) ==
    /\ meta[o].pc="return"
    /\ LET take == meta[o].kind="take" /\ meta[o].ok IN
       /\ ownerRange'=[ownerRange EXCEPT ![o]=IF take THEN meta[o].nextRange ELSE @]
       /\ ready'=[ready EXCEPT ![o]=@ \/ take]
       /\ nextId'=[nextId EXCEPT ![o]=IF take THEN (meta[o].nextRange-1)*Block+1 ELSE @]
       /\ maxRead'=[maxRead EXCEPT ![o]=IF take THEN (meta[o].nextRange-1)*Block ELSE @]
       /\ ack'=[ack EXCEPT ![o]=IF take THEN meta[o].ack ELSE @]
    /\ meta'=[meta EXCEPT ![o]=IdleMeta]
    /\ UNCHANGED <<rows,catalog,committed,required,discharged,durableRange,durableAck,write,gc,badDelete,badFence>>
CaptureGC(o) ==
    /\ ready[o] /\ gc[o]=-1 /\ ack[o]>0
    /\ gc'=[gc EXCEPT ![o]=ack[o]]
    /\ UNCHANGED <<rows,catalog,committed,required,discharged,durableRange,durableAck,ownerRange,ready,nextId,maxRead,ack,write,meta,badDelete,badFence>>
DeleteGC(o) ==
    /\ gc[o]>=0
    /\ LET bound == gc[o] + IF Mutant="past-bound" THEN 1 ELSE 0
           removed == First({r \in rows : r<=bound},2)
       IN /\ rows'=rows \ removed
          /\ badDelete'=(badDelete \/ (\E r \in removed : ~Covered(catalog[r],rows \ removed,durableAck)))
    /\ gc'=[gc EXCEPT ![o]=-1]
    /\ UNCHANGED <<catalog,committed,required,discharged,durableRange,durableAck,ownerRange,ready,nextId,maxRead,ack,write,meta,badFence>>
Next ==
    \/ \E o \in O : \E w \in Work : Reserve(o,w)
    \/ \E o \in O : CommitWrite(o) \/ RejectWrite(o) \/ ReturnWrite(o)
    \/ \E w \in Work : Discharge(w)
    \/ \E o \in O : \E b \in 0..(2*Block) : AdvanceAck(o,b) \/ CaptureSync(o,b)
    \/ CaptureTakeover
    \/ \E o \in O : CommitMetadata(o) \/ RejectMetadata(o) \/ ReturnMetadata(o)
    \/ \E o \in O : CaptureGC(o) \/ DeleteGC(o)
Spec == Init /\ [][Next]_vars
TypeOK == rows \subseteq committed /\ committed \subseteq Ids
          /\ required \subseteq Work /\ discharged \subseteq required
          /\ durableRange \in {1,2} /\ durableAck \in 0..(2*Block)
          /\ catalog \in [Ids -> Work \cup {0}]
          /\ badDelete \in BOOLEAN /\ badFence \in BOOLEAN
WorkCovered == \A w \in required : Covered(w,rows,durableAck)
DeletionSound == ~badDelete
FencedWrites == ~badFence
Symmetry == Permutations(Work)
=============================================================================
