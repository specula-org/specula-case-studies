------------------------------ MODULE PortsWrk ------------------------------
\* Port shape of the WORKER group (v10, profile taskMode): Kubernetes task
\* execution of one client site, pin c411a201. The group spans
\* CJ: TaskWorkerExecutor + TaskSupervisor (task_worker_executor.py,
\* task_worker/supervisor.py), per CJ launch l;
\* worker Pods (task_worker_process -> worker.run_worker), one per physical
\* attempt w = <<l, a>> (attempt ID = sha256(launch ID, server attempt),
\* task_worker_executor.py:159-166);
\* the job PVC store (task_worker/artifacts.py) and the committed checkpoint
\* manifest (one slot per job/executor/task name);
\* CP: K8sTaskService._Job (app_opt/task_launcher/k8s_task_service.py), the
\* per-CJ-launch task owner that creates, observes and deletes Pods.
\* The CJ<->CP task-control channel (k8s_task_control launch/poll/cancel/close)
\* is group-internal; its loss is the fault ctrlLoss.
\* pWorker[c]:
\* out[l] : None or [gen, kind, reason]; the executor's return to TaskCJ
\* for task number gen of launch l. kind: result | error |
\* aborted | interrupted (TaskExecutionInterrupted: CJ exits)
\* pod[w] : none | running | sent | done | failed | crashed | killed
\* (sent = the script handed its result off; done = completion
\* published, exit 0; failed = failure.json, exit 1; crashed =
\* nonzero exit without records; killed = deleted by CP)
\* store[w] : [created, completion, failure, payload] on the PVC
\* (payload = result payload present, cleared by release)
\* ckpt : None or [asg, w]: committed checkpoint manifest (the server
\* assignment it advanced and the attempt whose result it binds)
\* committed : assignments whose checkpoint was ever committed (history)
\* owner[l] : CP task owner of CJ launch l: none (open once launch l is
\* spawned) | closed | released | done (thread exited)
\* att[w] : CP view of attempt w: none | created | deleting | settled
EXTENDS Consts
\* workerCrash: the Pod exits nonzero without completion or failure records
\* (OOM kill, node loss with confirmed shutdown, scheduler wall time).
\* workerFail: the script/finalizer fails; failure.json, exit 1.
\* taskStageFail: create_attempt / write_input / bootstrap staging fails in CJ.
\* ctrlLoss: a CJ->CP launch reply is lost or times out (TaskLaunchError).
\* settleTimeout: CJ cannot confirm settlement within its bound (fence).
\* taskDeadline: worker_timeout / result_wait / finalization deadline expires.
WrkFaults == {"workerCrash", "workerFail", "taskStageFail", "ctrlLoss", "settleTimeout", "taskDeadline"}
WAttempts == Launches \X Attempts
EmptyRecord == [created |-> FALSE, completion |-> FALSE, failure |-> FALSE, payload |-> FALSE]
\* Outside taskMode the port is a constant 0 (no Worker step is enabled).
WorkerPortInit == IF ~TaskMode THEN 0 ELSE
                  [c \in Sites |-> [out |-> [l \in Launches |-> None],
                     pod |-> [w \in WAttempts |-> "none"],
                     store |-> [w \in WAttempts |-> EmptyRecord],
                     ckpt |-> None, committed |-> {},
                     owner |-> [l \in Launches |-> "none"],
                     att |-> [w \in WAttempts |-> "none"]]]
PodLive(s) == s \in {"running", "sent"}
PodExited(s) == s \in {"done", "failed", "crashed", "killed"}
=============================================================================
