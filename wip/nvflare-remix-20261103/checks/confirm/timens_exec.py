"""Exec a command in a new time namespace whose CLOCK_MONOTONIC is shifted by OFFSET seconds.

Models "this process runs on a node with a different boot time". util-linux unshare rejects
negative offsets, so this writes /proc/self/timens_offsets itself. The command replaces this
process (same PID, same process group), and enters the namespace on exec.
Usage: python timens_exec.py OFFSET CMD [ARGS...]
"""

import os
import sys

offset = int(sys.argv[1])
uid, gid = os.getuid(), os.getgid()
os.unshare(os.CLONE_NEWUSER | os.CLONE_NEWTIME)
for name, value in (("setgroups", "deny"), ("uid_map", f"{uid} {uid} 1"), ("gid_map", f"{gid} {gid} 1")):
    with open(f"/proc/self/{name}", "w") as stream:
        stream.write(value)
with open("/proc/self/timens_offsets", "w") as stream:
    stream.write(f"monotonic {offset} 0")
os.execv(sys.argv[2], sys.argv[2:])
