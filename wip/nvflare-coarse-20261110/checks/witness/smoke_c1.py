# Chunk-1 composition smoke (PROMPT step 5 acceptance): simulation from Init, every generic
# property item; "reached" = a violation, to be triaged. Fault-free runs must stay clean;
# the fault runs (chunk-1 faults with their neighbours' ops events) feed triage.
_ALL = ('QAll /\\ S1ThreadsAlive /\\ S3Resources /\\ S4NoLostResult /\\ S4Completed /\\ S5StatusMeaning '
        '/\\ S6AckMeansDone /\\ S7StopHasSource /\\ S8LossNotified /\\ S4OutputsDelivered')
W = {
 "smoke-fedavg2": dict(config="fedavg2", faults=[], phase=0, inv=_ALL),
 "smoke-k8s": dict(config="k8s", faults=[], phase=0, inv=_ALL),
 "smoke-multijobcp": dict(config="multijobcp", faults=[], phase=0, inv=_ALL),
 "smoke-attach": dict(config="attach", faults=[], phase=0, inv=_ALL),
 "smokeF-fedavg2": dict(config="fedavg2", faults=["cpCrash", "rpcTimeout", "slowRegister", "loginError",
                                                 "adminRemove", "adminDisable"], phase=0, inv=_ALL),
}
