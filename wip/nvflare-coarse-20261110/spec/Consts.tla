------------------------------- MODULE Consts -------------------------------
\* Constants, process identities, message records and pure helpers shared by
\* every module. No variables here.
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

CONSTANTS Sites,        \* client site identities (model values; symmetric)
          None,         \* model value for "absent"
          JobId,        \* the single job of this slice
          MaxLaunch,    \* CJ launch generations per site (>= 1)
          MaxAttempt,   \* server-issued task attempts per site (>= 1)
          Faults,       \* set of enabled fault names
          Profile       \* set of non-default NVFlare policy switches (ProfileSwitches)
ASSUME MaxLaunch \in Nat \ {0} /\ MaxAttempt \in Nat \ {0}
\* Profile switches (default {} = the slice profile of the seeds). Unlike
\* Faults they are configuration, not events: never priced, always on.
\* lossBudget3 Net_L may lose up to 3 messages (default 1)
\* wfTolerant workflow min_clients = |Sites|-1 and no required sites: a dead
\* client does not panic the job while enough clients remain
\* nonStrictStart start_job reply check non-strict (NVFlare's default,
\* STRICT_START_JOB_REPLY_CHECK = False, job_runner.py:364-404):
\* a timed-out START reply silently drops the site from the
\* active sites and the pending outcomes
\* otherJob a second job runs on every CP with its own GPU allocation
\* (max_jobs >= 2); only its CP-global env write is modeled
\* errResilient FedAvg ignore_result_error=True: a non-OK result is rejected
\* without a panic (FedAvg's default None needs every target,
\* since it passes no min_responses, so it behaves as strict)
\* cseTasks each round's work is scheduled as one task per site with that
\* site as the only target, in a fixed site order (the client-
\* controlled CSE server controller, ccwf/cse_server_ctl.py:
\* 186-200); the model's round task stands for that group. Not
\* symmetric in Sites (the order is fixed): no symmetry reduction.
\* taskMode (v10) the client app uses execution_lifetime "task" on the
\* Kubernetes task backend: TaskWorkerExecutor runs every
\* assignment in a fresh worker Pod (Worker group, PortsWrk)
\* v11 (DESIGN 16, coarse-only content; mkmc refuses fine variants of the
\* groups listed in COARSE_ONLY for each switch):
\* sjModel the SJ aggregator / persistor is the group Model (call-return
\* handshake from WfSJ for accept, aggregate, save)
\* sag ScatterAndGather workflow (scatter_and_gather.py)
\* cyclic Cyclic relay workflow (cyclic_ctl.py)
\* cseServer server-controlled cross-site model evaluation (standing
\* validation broadcasts, cross_site_model_eval.py)
\* swarm client-controlled Swarm (CCWF server_ctl + group Swarm)
\* k8sJob / dockerJob the CJ runs as a Kubernetes Pod / Docker container
\* multiJobCP a second job J2 with its own allocation and CJ on every CP
\* sampling FedAvg client sampling (per-round target subset)
V11Switches == {"sjModel", "sag", "cyclic", "cseServer", "swarm", "k8sJob", "dockerJob",
                "multiJobCP", "sampling"}
ProfileSwitches == {"lossBudget3", "wfTolerant", "nonStrictStart", "otherJob", "errResilient", "cseTasks", "multiJob", "taskMode"}
                   \cup V11Switches
ASSUME Profile \subseteq ProfileSwitches
TaskMode == "taskMode" \in Profile
\* workflow policy of the SJ controller (default FedAvg)
WfPolicies == {"sag", "cyclic", "cseServer", "swarm", "cseTasks"}
ASSUME Cardinality(Profile \cap WfPolicies) <= 1
ASSUME ~({"k8sJob", "dockerJob"} \subseteq Profile)
SJModel == "sjModel" \in Profile
\* cseTasks keeps the FedAvg round structure (one task group per round)
V11Wf == {"sag", "cyclic", "cseServer", "swarm"}
WfPolicy == IF Profile \cap V11Wf = {} THEN "fedavg" ELSE CHOOSE p \in Profile \cap V11Wf : TRUE
\* the CJ runs in its own container (Pod / Docker): it outlives a CP restart
CJContainer == {"k8sJob", "dockerJob"} \cap Profile /= {}

Launches == 1..MaxLaunch
Attempts == 1..MaxAttempt

SP == <<"SP">>
SJ == <<"SJ">>
CP(c) == <<"CP", c>>
CJ(c) == <<"CJ", c>>
Processes == {SP, SJ} \cup {CP(c) : c \in Sites} \cup {CJ(c) : c \in Sites}

\* A message key is unique per protocol identity. Variants of a group MUST use
\* identical keys and bodies for the same protocol event (interaction preservation).
MsgKey(kind, from, to, id) == <<kind, from, to, id>>
Msg(kind, from, to, id, body) ==
    [kind |-> kind, from |-> from, to |-> to, id |-> id, body |-> body]
\* net: key -> [msg |-> Msg, lost |-> BOOLEAN]
\* Existing entries are immutable (C3): re-sending the IDENTICAL message under an
\* existing key is a no-op (under Net_L a lost message then stays lost: a
\* conservative under-approximation of the resend); a different message under an
\* existing key still overwrites, so the stepping group's NetOK assertion flags it.
Send(n, m) == [k \in DOMAIN n \cup {MsgKey(m.kind, m.from, m.to, m.id)} |->
                 IF k \in DOMAIN n /\ (k /= MsgKey(m.kind, m.from, m.to, m.id) \/ n[k].msg = m)
                 THEN n[k] ELSE [msg |-> m, lost |-> FALSE]]
SendAll(n, ms) == [k \in DOMAIN n \cup {MsgKey(m.kind, m.from, m.to, m.id) : m \in ms} |->
                 LET new == {m \in ms : k = MsgKey(m.kind, m.from, m.to, m.id)} IN
                 IF k \in DOMAIN n /\ (new = {} \/ \A m \in new : n[k].msg = m)
                 THEN n[k]
                 ELSE [msg |-> CHOOSE m \in new : TRUE, lost |-> FALSE]]
Fresh(n, m) == MsgKey(m.kind, m.from, m.to, m.id) \notin DOMAIN n

\* Identities shared across components.
Token(c, l) == <<"token", c, l>>
Assignment(c, a) == [job |-> JobId, task |-> "train", clientTask |-> <<"ct", c, a>>,
                     attempt |-> a, site |-> c]
Tx(c, l, a) == <<"tx", c, l, a>>
Ref(c, l, a) == <<"ref", c, l, a>>
ResultValue(c, a) == <<"result", c, a>>
Descriptor(c, l, a) == [ref |-> Ref(c, l, a), source |-> CJ(c), launch |-> l]
=============================================================================
