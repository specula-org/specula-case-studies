---------------------------- MODULE Env_Trainer ----------------------------
\* Environment ASSUMPTION of the Trainer group (assume-guarantee, DESIGN.md §2.1).
\* Two forms that must describe the same transitions on the Trainer's reads:
\*   EnvNext    generator form: concrete port updates, explored by the harness
\*   EnvAllowed checker form: a predicate on (Reads, Reads'), checked as the
\*              discharge property AG_Trainer in mixes / neighbor harnesses
\* Trainer reads: pTaskCJ[c][l].input / .trainerSignal (executor handshake),
\* pRunCJ[c][l].ready, CJAlive(c,l), pJobCP[c].launch; its own pTrainer.
\* Source of the assumption: in_process_backend.py:152-250 (execute() delivers
\* task k only after task k-1's execute() returned with a newer result; a
\* timeout/abort fires TOPIC_ABORT and latches _abort, after which no input is
\* delivered); client_runner.py:791-821 (readiness), process exit.
EXTENDS Ports
CONSTANT MaxGen

In(c, l) == IF Has(pTaskCJ[c][l], "input") THEN pTaskCJ[c][l].input ELSE None
Sig(c, l) == IF Has(pTaskCJ[c][l], "trainerSignal") THEN pTaskCJ[c][l].trainerSignal ELSE "none"
Gen(x) == IF x = None THEN 0 ELSE x.gen
PubCount(c, l) == IF pTrainer[c][l].published = None THEN 0 ELSE pTrainer[c][l].published.seq

Reads == [c \in Sites |-> [l \in Launches |->
            [gen |-> Gen(In(c, l)), sig |-> Sig(c, l), ready |-> pRunCJ[c][l].ready,
             alive |-> CJAlive(c, l)]]]

\* ---------- generator form (harness)
EnvLaunch(c) ==
    /\ CurLaunch(c) < MaxLaunch /\ (CurLaunch(c) = 0 \/ ~CJAlive(c, CurLaunch(c)))
    /\ pJobCP' = [pJobCP EXCEPT ![c].launch = @ + 1]
    /\ UNCHANGED <<pRunCJ, pTaskCJ>>
EnvReady(c, l) ==
    /\ CJAlive(c, l) /\ ~pRunCJ[c][l].ready
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].ready = TRUE, ![c][l].state = "running"]
    /\ UNCHANGED <<pJobCP, pTaskCJ>>
EnvInput(c, l) ==
    LET k == Gen(In(c, l)) + 1 IN
    \* no signal guard: TaskCJ_C (coarse executor) may publish after ABORT; the
    \* fine executor never does (in_process_backend.py:162-173), but the
    \* assumption must cover every variant the receipt is used with.
    /\ CJAlive(c, l) /\ k <= MaxGen
    /\ pTrainer[c][l].received = k - 1 /\ PubCount(c, l) >= k - 1
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].input = [gen |-> k, assignment |-> None, value |-> k]]
    /\ UNCHANGED <<pJobCP, pRunCJ>>
\* The executor fires TOPIC_ABORT (abort/timeout/exception) and, at finalize,
\* TOPIC_STOP (in_process_backend.py:200-260); the port keeps the LAST topic, so
\* any change into abort/stop is allowed (discharge found abort->stop, stop->abort).
EnvSignal(c, l, s) ==
    /\ Sig(c, l) /= s
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].trainerSignal = s]
    /\ UNCHANGED <<pJobCP, pRunCJ>>
EnvDie(c, l) ==
    /\ CJAlive(c, l)
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].exit = "crash", ![c][l].state = "exited"]
    /\ UNCHANGED <<pJobCP, pTaskCJ>>
EnvNext == \/ \E c \in Sites : EnvLaunch(c)
           \/ \E c \in Sites, l \in Launches :
                EnvReady(c, l) \/ EnvInput(c, l) \/ EnvDie(c, l)
                \/ \E s \in {"abort", "stop"} : EnvSignal(c, l, s)
EnvVars == <<pJobCP, pRunCJ, pTaskCJ>>

\* ---------- checker form (discharge): per (site, launch), every observed change
\* is one of the generator's moves (simultaneous independent changes are a
\* sequentialization the harness also explores).
FieldOK(c, l) ==
    LET r == Reads[c][l]  r2 == Reads'[c][l] IN
    /\ r2.gen = r.gen \/ (r2.gen = r.gen + 1 /\ r.alive
                          /\ pTrainer[c][l].received = r.gen /\ PubCount(c, l) >= r.gen)
    /\ r2.sig = r.sig \/ r2.sig \in {"abort", "stop"}
    /\ r2.ready = r.ready \/ (~r.ready /\ r2.ready /\ r.alive)
    /\ r2.alive = r.alive \/ (r.alive /\ ~r2.alive)
              \/ (~r.alive /\ r2.alive /\ CurLaunch(c) < l /\ CurLaunch(c)' = l)
EnvAllowed == \A c \in Sites, l \in Launches : FieldOK(c, l)
=============================================================================
