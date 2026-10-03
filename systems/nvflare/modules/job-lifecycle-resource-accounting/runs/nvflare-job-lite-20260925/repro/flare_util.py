"""Helpers for the reproduction tests: FLARE admin API session + observation helpers (no product changes)."""
import glob
import os
import time

from nvflare.fuel.flare_api.flare_api import new_secure_session

R = os.path.dirname(os.path.abspath(__file__))
POC = os.path.join(R, "poc_ws", "example_project", "prod_00")
ADMIN_KIT = os.path.join(POC, "admin@nvidia.com")
SERVER_WS = os.path.join(POC, "server")


def session(timeout=30.0):
    return new_secure_session("admin@nvidia.com", ADMIN_KIT, timeout=timeout)


def status(sess, job_id):
    try:
        meta = sess.get_job_meta(job_id)
    except Exception as e:  # deleted jobs etc.
        return f"<error: {type(e).__name__}: {e}>"
    return meta.get("status")


def wait_status(sess, job_id, pred, timeout=120.0, poll=0.5):
    t0 = time.time()
    st = None
    while time.time() - t0 < timeout:
        st = status(sess, job_id)
        if pred(st):
            return st
        time.sleep(poll)
    return st


def server_log():
    return os.path.join(SERVER_WS, "log.txt")


def server_run_dir(job_id):
    return os.path.join(SERVER_WS, job_id)


def grep_file(path, needle):
    try:
        with open(path, errors="replace") as f:
            return [l.rstrip("\n") for l in f if needle in l]
    except FileNotFoundError:
        return []


def log_offset(path):
    try:
        return os.path.getsize(path)
    except FileNotFoundError:
        return 0


def log_since(path, offset):
    try:
        with open(path, errors="replace") as f:
            f.seek(offset)
            return f.read()
    except FileNotFoundError:
        return ""


def client_run_dirs(job_id):
    return sorted(glob.glob(os.path.join(POC, "site-*", job_id)))


def sj_processes(job_id):
    """PIDs of server job (SJ) / client job (CJ) processes for job_id, observed via /proc."""
    pids = {"sj": [], "cj": []}
    for p in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            with open(p, "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode(errors="replace")
        except Exception:
            continue
        if job_id in cmd:
            if "runner_process" in cmd:
                pids["sj"].append(int(p.split("/")[2]))
            elif "worker_process" in cmd:
                pids["cj"].append(int(p.split("/")[2]))
    return pids
