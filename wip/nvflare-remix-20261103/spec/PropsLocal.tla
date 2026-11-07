----------------------------- MODULE PropsLocal -----------------------------
\* Properties over the private state of a FINE group. They are checked only
\* where that group is fine and are vacuous for coarse sites (DESIGN.md §2:
\* a property over ports plus the private state of the groups kept fine
\* transfers to all-fine).
EXTENDS Mix
\* H08 (Phase 1 S01): a live CJ's GPU env names only its own allocation.
LEnvMatchesAllocation == GrainHas("JobCP", "F") => JobCP_F!EnvMatchesAllocation

\* H11 precursor: no ClientTask is listed twice in a task's client_tasks
LNoDupClientTask == GrainHas("CommSJ", "F") =>
    \A t \in 1..Rounds : Len(commSJ_f.task[t].assignedOrder) =
                         Cardinality({commSJ_f.task[t].assignedOrder[i] : i \in 1..Len(commSJ_f.task[t].assignedOrder)})

\* T1-b precursor check: the scheduling loop died after deployment had started
LNoCrashAfterDeploy == GrainHas("JobSP", "F") =>
    ~(jobSP_f.scheduler.pc = "crashed" /\ "deploy" \in jobSP_f.ms)

\* ---- directed reachability (CONSTRAINT), not for blind hunts
\* only TASK_ASSIGNMENT replies are lost (H11 needs a GET_TASK retry)
OnlyAssignmentLoss == \A k \in DOMAIN net : net[k].lost => net[k].msg.kind = "TASK_ASSIGNMENT"

\* H03 (Phase 1 rank 10; REPRODUCED with a forced schedule, checks/confirm/h03_repro.py):
\* an external trainer is stopped only for a live source whose failure was
\* notified to its receivers (or with no live source)
LTrainerStopOwner == Grain["Trainer"] /= "X" \/
    \A c \in Sites, l \in Launches : trainer_x[c][l].victim = 0 \/ trainer_x[c][l].victim \in trainer_x[c][l].notices
\* ---- v9 SP shutdown (JobSP_F): what fl_shutdown -> stop_all_jobs promises
\* every job still in run_processes when the shutdown finishes was stopped by it
LShutdownStopsAll == jobSP_f.shut.pc = "done" =>
    \A k \in DOMAIN jobSP_f.jobs : jobSP_f.jobs[k].serverRegistered => k \in jobSP_f.shut.stopped
\* SYSTEM_END is fired on every shutdown (resource managers stop their threads)
LSystemEndOnShutdown == jobSP_f.shut.pc = "done" => jobSP_f.shut.sysEnd
\* no SJ is launched once the shutdown has begun
LNoSpawnAfterShutdown == [][jobSP_f.shut.pc /= "none" =>
    \A k \in DOMAIN jobSP_f.jobs : jobSP_f'.jobs[k].serverSpawned => jobSP_f.jobs[k].serverSpawned]_jobSP_f
\* the same with the known S4 excluded: only the job the scheduling pass was already
\* handling when the shutdown began may still be launched (ask_to_stop is read at the loop top)
LNoSpawnAfterShutdownK == [][jobSP_f.shut.pc /= "none" =>
    \A k \in DOMAIN jobSP_f.jobs : (jobSP_f'.jobs[k].serverSpawned /\ ~jobSP_f.jobs[k].serverSpawned)
                                    => k = jobSP_f.shut.passJob]_jobSP_f
\* the jobs listed in run_processes when the shutdown began and still there at its end
\* were stopped (S1 breaks it; jobs registered later are S4)
LShutdownStopsAllK == jobSP_f.shut.pc = "done" =>
    \A k \in jobSP_f.shut.snap : jobSP_f.jobs[k].serverRegistered => k \in jobSP_f.shut.stopped

=========================================================================
