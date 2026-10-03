# Scratch child: runs a main function through the real MainProcessMonitor.run funnel
# exactly like runner_process.py / worker_process.py do (rc = mpm.run(...); sys.exit(rc)).
import sys
import threading
import time

from nvflare.fuel.common.excepts import ComponentNotAuthorized, ConfigError
from nvflare.fuel.f3.mpm import MainProcessMonitor as mpm


def main(mode, linger):
    if linger:
        # a non-daemon thread still alive at MPM exit -> mpm writes rc file + os._exit
        threading.Thread(target=time.sleep, args=(8.0,), daemon=False, name="lingering").start()
    if mode == "ok":
        return None
    if mode == "config":
        raise ConfigError("bad job config")
    if mode == "unsafe":
        raise ComponentNotAuthorized("component not authorized")
    if mode == "exc":
        raise RuntimeError("boom")
    if mode == "sysexit":
        sys.exit(1)
    if mode == "sigkill":
        import os
        import signal

        os.kill(os.getpid(), signal.SIGKILL)
    raise ValueError(mode)


if __name__ == "__main__":
    mode, linger, run_dir = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
    rc = mpm.run(main_func=main, run_dir=run_dir, mode=mode, linger=linger)
    sys.exit(rc)
