#!/usr/bin/env python3
"""Probe: does ProcessHandle.terminate() (killpg via getpgid(leader)) reach job descendants after the leader exited?
Uses the REAL nvflare.utils.process_utils.spawn_process + nvflare.app_common.job_launcher.process_launcher.ProcessHandle.
The spawned 'job' is /bin/sh that starts a background descendant (same process group) and then exits (leader exit),
standing in for a job process whose helper subprocess outlives it."""
import os, signal, sys, tempfile, time
SOURCE = "/home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/full/source"
import nvflare
assert os.path.realpath(nvflare.__file__).startswith(SOURCE)
from nvflare.utils.process_utils import spawn_process
from nvflare.app_common.job_launcher.process_launcher import ProcessHandle

def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False

def run(case):
    d = tempfile.mkdtemp()
    pidfile = os.path.join(d, "child.pid")
    hold = "sleep 30" if case == "leader_alive" else "true"
    argv = ["/bin/sh", "-c", f"sleep 120 & echo $! > {pidfile}; {hold}; exit 0"]
    handle = ProcessHandle(process_adapter=spawn_process(argv, dict(os.environ)))
    for _ in range(50):
        if os.path.exists(pidfile) and open(pidfile).read().strip():
            break
        time.sleep(0.1)
    child = int(open(pidfile).read().strip())
    leader = handle.adapter.pid
    print(f"[{case}] leader pid={leader} pgid(child)={os.getpgid(child)} descendant pid={child}")
    if case == "leader_exited":
        handle.wait()  # what JobExecutor._wait_child_process_finish does before freeing resources
        print(f"[{case}] leader exited, poll()={handle.poll()} ; descendant alive={alive(child)}")
    handle.terminate()  # abort / cleanup path (client _terminate_job, server _remove_run_processes)
    time.sleep(0.5)
    if case == "leader_alive":
        handle.wait()
    survived = alive(child)
    print(f"[{case}] after terminate(): descendant alive={survived}")
    if survived:
        os.kill(child, signal.SIGKILL)  # probe cleanup
    return survived

r1 = run("leader_alive")
r2 = run("leader_exited")
print(f"RESULT leader_alive->descendant_survived={r1} ; leader_exited->descendant_survived={r2}")
