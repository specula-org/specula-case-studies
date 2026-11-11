# Chunk 1 witnesses: every modeled outcome of the chunk-1 ledger rows is reachable
# (PROMPT step 5 acceptance). Each: config of plans/calib2.py, faults, start phase, and a
# property whose violation means "reached". Not used by the sweep.
W = {
 "c1-remove": dict(config="fedavg", faults=["adminRemove"], phase=2, inv='\\A c \\in Sites : pReg.reg[c]'),
 "c1-remove-participant": dict(config="fedavg", faults=["adminRemove"], phase=2, inv='pReg.dropped /= "Reg.admin.remove"'),
 "c1-reactivate": dict(config="fedavg", faults=["adminRemove"], phase=2,
                       act='[][~(\\E c \\in Sites : ~pReg.reg[c] /\\ pReg\'.reg[c] /\\ pReg\'.tok[c] = pReg.tok[c])]_pReg'),
 "c1-disable": dict(config="fedavg", faults=["adminDisable"], phase=2, inv='pReg.dropped /= "Reg.admin.disable"'),
 "c1-enable": dict(config="fedavg", faults=["adminDisable"], phase=2,
                   act='[][~(\\E c \\in Sites : pReg.disabled[c] /\\ ~pReg\'.disabled[c])]_pReg'),
 "c1-login-begin": dict(config="fedavg", faults=["cpCrash"], phase=2, inv='\\A c \\in Sites : pLogin[c].st /= "registering"'),
 "c1-login-ok": dict(config="fedavg", faults=["cpCrash"], phase=2,
                     inv='~(\\E c \\in Sites : pLogin[c].tok0 > 0 /\\ pLogin[c].st = "up" /\\ pLogin[c].adminCb)'),
 "c1-login-slow": dict(config="fedavg", faults=["cpCrash", "slowRegister"], phase=2,
                       inv='\\A c \\in Sites : pLogin[c].connErr = "none"'),
 "c1-login-rejected": dict(config="fedavg", faults=["cpCrash", "adminDisable"], phase=2,
                           inv='\\A c \\in Sites : pLogin[c].st /= "exited"'),
 "c1-login-error": dict(config="fedavg", faults=["cpCrash", "loginError"], phase=2,
                        inv='\\A c \\in Sites : pLogin[c].st /= "exited"'),
 "c1-outcome-dropped": dict(config="fedavg", faults=["adminRemove"], phase=2,
                            act='[][~(\\E k \\in DOMAIN net : net[k].msg.kind = "OUTCOME" /\\ k \\notin jobSP_c.handled '
                                '/\\ k \\in jobSP_c\'.handled /\\ jobSP_c\'.pending = jobSP_c.pending /\\ \\E c \\in Sites : ~pReg.reg[c])]_<<jobSP_c>>'),
 "c1-deaf-check-timeout": dict(config="fedavg", faults=["cpCrash", "slowRegister"], phase=0,
                               inv='~(jobSP_c.stage = "blocked" /\\ CPDeaf)'),
 "c1-stop-precheck-after-abort": dict(config="fedavg", faults=["abort", "spShutdown"], phase=2,
                                      inv='~(jobSP_c.shut = "loop" /\\ jobSP_c.registered /\\ jobSP_c.runAborted)'),
}
