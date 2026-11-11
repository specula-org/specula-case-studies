#!/usr/bin/env python3
"""Write notes/ledger.d/11_c1.py: the reviewed ledger rows of chunk 1 (PROMPT step 5).
Every unit that scripts/extract_units.py found in chunk 1 gets a reviewed status (the
file's decision below, read from the code); the units that are modeled get their own
rows (MODELED) with outcomes, reasons, effects and actions."""
import csv
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
TC = "private/fed/server/training_cmds.py"; SE = "private/fed/server/server_engine.py"
CM = "private/fed/server/client_manager.py"; FS = "private/fed/server/fed_server.py"
FCB = "private/fed/client/fed_client_base.py"; CT = "private/fed/app/client/client_train.py"
AU = "private/fed/authenticator.py"; CO = "private/fed/client/communicator.py"

# id, file_line, unit_type, group, outcomes, reasons, effects, status, actions, lifetime, sharing
MODELED = [
    ("Reg.admin.remove", TC + ":184-193; " + SE + ":611-615,667-671", "H", "Reg",
     "OK (token entry removed); the cleanup thread's logout notifies the client's jobs, this path does not",
     "adminRemove (admin command)", "pReg.reg[c] = FALSE; admin_server.client_dead; no HANDLE_DEAD_JOB; cause record pReg.dropped",
     "modeled", "Reg_C!AdminRemove", "process", "cross-job"),
    ("Reg.admin.disable", TC + ":195-209; " + SE + ":621-645; " + CM + ":117-141", "H", "Reg",
     "OK (name disabled and persisted, tokens dropped); FB (persisting the disabled set raises: rolled back, error reply, no effect: omitted)",
     "adminDisable (admin command)", "pReg.disabled[c], reg[c] = FALSE; later heartbeats and logins of the name rejected; no HANDLE_DEAD_JOB; cause record pReg.dropped",
     "modeled", "Reg_C!AdminDisable", "persistent", "cross-job"),
    ("Reg.admin.enable", TC + ":211-225; " + SE + ":647-665", "H", "Reg", "OK", "adminDisable (admin command)",
     "pReg.disabled[c] = FALSE", "modeled", "Reg_C!AdminEnable", "persistent", "cross-job"),
    ("Reg.mgr.heartbeat", CM + ":376-417; " + FS + ":968-1011", "H", "Reg",
     "OK (known token: refreshed); unknown token of a live CP: re-activated with the same token; FB: a disabled name is rejected (UNAUTHENTICATED)",
     "R-absent (token entry removed); R-state (name disabled)", "pReg.reg[c] = TRUE (same generation)",
     "modeled", "Reg_C!Reactivate;Reg_C!GoStale", "process", "cross-job"),
    ("JobSP.admin.stopPrecheck", TC + ":148-182,262-298", "H", "JobSP",
     "OK (shutdown / restart accepted); FB (refused: a job in running_jobs not aborted; restart: any job there)",
     "R-state", "accepted: the shutdown loop starts (JobSP.admin.shutdownLoop). Jobs being scheduled or started are not in running_jobs and not seen",
     "modeled", "JobSP_C!ShutStart", "process", "cross-job"),
    ("JobSP.recv.outcomeAuth", FS + ":909-940", "H", "JobSP",
     "OK; FB (the reporting token is not registered: the outcome is dropped)", "R-absent (token removed / disabled)",
     "pending outcome kept", "modeled", "JobSP_C!RecvOutcome", "process", "cross-process"),
    ("JobSP.x.cpDeafTimeout", "private/fed/server/message_send.py:60-111; " + SE + ":1008-1012", "X", "JobSP",
     "an admin-channel request to a CP that does not serve the channel times out (not a fault: a consequence)",
     "R-state (the CP's admin channel is not registered)", "CHECK / DEPLOY / START replies missing: the scheduler cancels, the runner fails or drops the site",
     "modeled", "JobSP_C!AdmitCancel;JobSP_C!RegisterRunning;JobSP_C!StartEval;JobSP_C!Fail", "process", "cross-process"),
    ("Login.cp.main", CT + ":68-185", "P", "Login",
     "start-up after a restart: connect, register, heartbeat, engine and admin agent; exits when registration fails",
     "cpCrash (restart)", "pLogin[c].st registering -> up / exited; an exited CP takes no further job-management step (Ports.CPAlive guards every JobCP action) and its heartbeats stop (Reg goes stale)", "modeled", "Login_C!Begin;Login_C!Registered;Login_C!Rejected", "process", "cross-process"),
    ("Login.cp.register", FCB + ":254-268; " + CO + ":327-436; " + AU + ":173-305", "X", "Login",
     "OK (token); FB: rejected (UNAUTHENTICATED: name disabled, client limit) or failed (no reply, bad reply, error): client_register stops the heartbeat and main raises Login failed, the CP exits; no token: retried",
     "R-state (disabled); loginError (no reply / error reply)", "pReg new token generation; pLogin.st", "modeled",
     "Login_C!Registered;Login_C!Rejected;Reg_C!ReLogin", "process", "cross-process"),
    ("Login.cp.connectWait", FCB + ":103-114,197-218; " + CT + ":79-110", "T", "Login",
     "OK (engine found, admin channel registered); FB: the engine is not set within engine_create_timeout (registration still running): the connect thread raises into connect_error, which main no longer reads; the admin channel is never registered",
     "slowRegister (registration outlasts engine_create_timeout after the cell exists)",
     "pLogin.adminCb; cause record pLogin.connErr", "modeled", "Login_C!Registered", "process", "cross-process"),
    ("Login.cp.adminChannel", "private/fed/client/admin.py:78-83; private/fed/server/message_send.py:76-85", "H", "Login",
     "SP->CP admin requests (CHECK_RESOURCES, DEPLOY, START, ABORT, admin commands) are dispatched only once register_cell_cb ran",
     "R-state (not registered)", "Ports.CPServes gates JobCP's command handlers", "modeled",
     "JobCP_C!RecvCheck;JobCP_C!RecvCancel;JobCP_C!RecvDeploy;JobCP_C!RecvStart", "process", "cross-process"),
    ("Login.cp.heartbeat", FCB + ":302-316,335-345; " + CO + ":686-740", "T", "Login",
     "OK (loop; failed sends retried every 5 s, UNAUTHENTICATED included); FB omitted: the thread ends if the engine is not set within 60 s, but main sets it right after starting the thread (no wait in between)",
     "-", "heartbeats (Reg.mgr.heartbeat); HEARTBEAT_STOP handled in the reply", "modeled",
     "JobCP_C!RecvAbort;Reg_C!GoStale", "process", "cross-process"),
]

# reviewed decisions for every extracted unit, by file (read from the code)
FILES = {
    "private/fed/app/client/client_train.py": "covered by Login.cp.main",
    "private/fed/app/deployer/base_client_deployer.py": "excluded: short-lived or local (built while the start-up configuration is parsed)",
    "private/fed/app/deployer/server_deployer.py": "covered by JobSP.proc.SP (SP start-up: server, job runner thread)",
    "private/fed/app/fl_conf.py": "excluded: short-lived or local (configuration parsing)",
    "private/fed/app/server/server_train.py": "covered by JobSP.proc.SP and Reg.proc.restart (SP process entry; restart / shutdown touch files)",
    "private/fed/app/utils.py": "covered by Ports.CJAlive / SJAlive (monitor_parent_process: a child process ends with its parent)",
    "private/fed/authenticator.py": "covered by Login.cp.register",
    "private/fed/client/fed_client_base.py": "covered by Login.cp.* (close / terminate / send_request_before_shutdown: CP shutdown on the admin command, chunk 2)",
    "private/fed/client/fed_client.py": "covered by TaskCJ.pull (pull / push in the CJ)",
    "private/fed/cmi.py": "excluded: short-lived or local (per-message header filters)",
    "private/fed_json_config.py": "excluded: short-lived or local (configuration parsing)",
    "private/fed/server/admin.py": "covered by Login.cp.adminChannel (send_requests); the admin server's own client table only targets admin replies, read by no job-path decision",
    "private/fed/server/cmd_utils.py": "excluded: short-lived or local (admin target validation and reply formatting)",
    "private/fed/server/cred_keeper.py": "excluded: STANDARD 8 security (identity assertion credentials)",
    "private/fed/server/info_coll_cmd.py": "excluded: read-only admin queries (stats, errors)",
    "private/fed/server/message_send.py": "covered by Login.cp.adminChannel and JobSP.x.cpDeafTimeout",
    "private/fed/server/run_manager.py": "excluded: short-lived or local (SP run manager configuration)",
    "private/fed/server/server_cmd_modules.py": "excluded: command module registration at start-up",
    "private/fed/server/server_command_agent.py": "covered by calibration rows: the SJ's command agent dispatches the SP's commands (abort -> WfSJ.runner.end, handle dead job -> CommSJ.wfc.deadClients)",
    "private/fed/server/server_commands.py": "covered by calibration rows (see server_command_agent)",
    "private/fed/server/server_json_config.py": "excluded: short-lived or local (configuration parsing)",
    "private/fed/server/site_security.py": "excluded: STANDARD 8 security (authorization)",
    "private/fed/server/study_cmds.py": "excluded: admin edits of the study registry; the scheduler reads it per scan (job_scheduler.py:119-150): a removed study site makes a queued job unschedulable by design (SUBMITTED until the admin acts)",
    "private/fed/server/sys_cmd.py": "excluded: read-only reports; configure_site_log is logging (STANDARD 8); dead_client is a manual remedy whose effect equals the cleanup thread's notification",
    "private/fed/server/training_cmds.py": "covered by Reg.admin.*, JobSP.admin.stopPrecheck (check_status and show_scopes are read-only)",
    "private/fed/tbi.py": "covered by WfSJ.runner.end (end-run readiness)",
    "private/fed/utils/app_deployer.py": "covered by JobCP.cmd.deploy and JobSP.x.deployApp",
    "private/fed/utils/fed_utils.py": "covered by JobCP.exec.report (return-code files) / excluded: start-up helpers",
    "private/json_configer.py": "excluded: short-lived or local (configuration parsing)",
}


def main():
    rows = list(MODELED)
    for u in csv.DictReader((ROOT / "notes" / "units-scope.csv").open()):
        if u["chunk"] != "c1":
            continue
        f = u["file_line"].split(":")[0]
        dec = FILES[f]
        status = dec if dec.startswith("excluded") else "excluded: " + dec
        rows.append((f"c1/{u['id']}", u["file_line"], u["unit_type"], "C1", "-", "-", u["effects"],
                     status + " [reviewed; rule: " + u["select"].split(":")[0] + "]", "", u["lifetime"], u["sharing"]))
    out = ROOT / "notes" / "ledger.d" / "11_c1.py"
    out.write_text("# GENERATED by scripts/ledger_c1.py: chunk 1 reviewed rows (modeled units, and a reviewed\n"
                   "# decision for every unit scripts/extract_units.py found in chunk 1)\nROWS = [\n"
                   + "".join(" " + repr(r) + ",\n" for r in rows) + "]\n")
    print(len(MODELED), "modeled,", len(rows) - len(MODELED), "reviewed candidates ->", out)


if __name__ == "__main__":
    main()
