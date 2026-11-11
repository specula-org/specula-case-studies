# Calibration sweep (PROMPT step 2): the region remix covers, failure point x phase.
OPS = ["cjCrash", "sjCrash", "cpCrash", "spCrash", "abort", "deleteJob", "spShutdown", "netLoss", "deadClient",
       "taskTimeout", "rpcTimeout"]
GENERIC = ["slowSJTeardown", "slowAdminStop", "statusLost", "abortCmdError", "outcomeReportFail", "deployError",
           "launchError", "storeError", "outcomeTimeout", "archiveError", "admissionError", "resExpiry",
           "slowShutdownAbort", "sjSyncFail",
           "submitTimeout", "prepFail", "cbFail", "cancel", "minClients", "resultWaitTimeout", "slowFinalize",
           "taskDataFail", "pullTimeout", "txTimeout", "payProduce", "payConsumer", "payCallback", "paySubmit",
           "payCompute", "payDelete", "sourceFailure", "slowEnvelope", "trainerError", "tpSilent", "regIterRace",
           "transportFail"]
# a failure point together with the events it needs to have any effect
DEPS = {"cpCrash": ["rpcTimeout"], "spCrash": ["rpcTimeout"], "slowShutdownAbort": ["spShutdown"], "slowAdminStop": ["abort"], "jobExitRace": ["deadClient"],
        "regIterRace": ["deadClient"], "monitorStale": ["tpSilent"], "statusLost": ["cbFail"],
        "slowFinalize": ["deadClient"], "slowPublish": ["cjCrash"], "podDeleteFail": ["abort"]}
P3 = [0, 2, 5]
P4 = [0, 2, 4, 5]
def cfg(points, sites=2, launch=1, attempt=1, profile=(), grain=None, phases=P3):
    return dict(points=points, sites=sites, launch=launch, attempt=attempt, profile=list(profile),
                grain=grain or {}, phases=phases)
CONFIGS = {
    "fedavg": cfg(OPS + GENERIC, sites=1, launch=2),
    "fedavg2": cfg(OPS + ["regIterRace", "slowFinalize", "minClients", "cancel", "transportFail", "submitTimeout"]),
    "nonstrict": cfg(OPS, launch=1, profile=["nonStrictStart"]),
    "multijob": cfg(OPS + ["jobExitRace", "regIterRace"], profile=["multiJob", "otherJob"]),
    "multijobcp": cfg(OPS + ["startOverlap"], sites=1, launch=2, profile=["multiJobCP"]),
    "cse": cfg(OPS, profile=["cseTasks"]),
    "cseserver": cfg(OPS + ["cbFail"], profile=["cseServer"]),
    "sag": cfg(OPS + ["acceptRaise", "saveFail", "cbFail"], profile=["sag", "sjModel"]),
    "cyclic": cfg(OPS + ["cbFail"], profile=["cyclic"]),
    "swarm": cfg(OPS + ["swarmMsgFail", "learnFail", "busyReplace", "gatherTimeout"], attempt=2,
                 profile=["swarm"], phases=P4),
    "k8s": cfg(OPS + ["podDeleteFail", "slowPublish"], sites=1, launch=2, profile=["k8sJob"]),
    "docker": cfg(OPS, sites=1, launch=2, profile=["dockerJob"]),
    "external": cfg(OPS + ["tpSilent", "monitorStale", "trainerError"], sites=1, attempt=2, grain={"Trainer": "X"},
                    phases=P4),
    "attach": cfg(OPS + ["tpAttachLate", "tpCrash", "tpReplyLost", "tpSilent", "trainerError", "resultWaitTimeout"],
                  sites=1, grain={"Trainer": "A"}),
    "taskmode": cfg(OPS + ["workerCrash", "workerFail", "taskStageFail", "ctrlLoss", "settleTimeout", "taskDeadline"],
                    sites=1, launch=2, profile=["taskMode"]),
    "sampling": cfg(OPS, profile=["sampling"]),
    "fedmodel": cfg(OPS + ["acceptRaise", "saveFail"], profile=["sjModel"]),
}
FILTERS = {}
