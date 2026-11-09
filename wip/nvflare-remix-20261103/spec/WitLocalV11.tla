---------------------------- MODULE WitLocalV11 ----------------------------
\* v11 smoke witnesses over the private state of v11 variants (EXTENDS Mix, like
\* PropsLocal). A violation means the named situation was reached.
EXTENDS Mix
AttachOn == Grain["Trainer"] = "A"
TA(c, l) == trainer_a[c][l]
WAttPublished == ~(AttachOn /\ \E c \in Sites, l \in Launches : pTrainer[c][l].published /= None)
WAttErr == ~(AttachOn /\ \E c \in Sites, l \in Launches : pTrainer[c][l].err > 0)
WAttErrFinished == ~(AttachOn /\ pJobSP.terminal /= "none" /\ \E c \in Sites, l \in Launches : pTrainer[c][l].err > 0)
\* H01: the trainer believes its result was accepted, the CJ never accepted it
WAttH01 == ~(AttachOn /\ \E c \in Sites, l \in Launches :
                TA(c, l).tpOut.out = "inferred" /\ TA(c, l).auth < TA(c, l).tpOut.gen)
WAttStopped == ~(AttachOn /\ \E c \in Sites, l \in Launches : pTrainer[c][l].stopped)
WAttReattach == ~(AttachOn /\ \E c \in Sites, l \in Launches : TA(c, l).tp = "open" /\ TA(c, l).auth > 0
                                                              /\ TA(c, l).tpGen = 0 /\ TA(c, l).gen > TA(c, l).auth)
=============================================================================
