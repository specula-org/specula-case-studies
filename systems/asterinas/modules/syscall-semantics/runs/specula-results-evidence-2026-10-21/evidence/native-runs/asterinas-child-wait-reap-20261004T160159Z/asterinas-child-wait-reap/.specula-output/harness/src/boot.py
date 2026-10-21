#!/usr/bin/env python3
"""Stop QEMU only after the fixture's completion marker, or fail on timeout."""
import argparse
import json
from pathlib import Path
import selectors
import socket
import subprocess
import time
import uuid

p = argparse.ArgumentParser()
p.add_argument("--kernel", required=True)
p.add_argument("--initramfs", required=True)
p.add_argument("--log", type=Path, required=True)
p.add_argument("--calibration", action="store_true")
p.add_argument("--outcome", action="store_true")
p.add_argument("scenario")
p.add_argument("value")
p.add_argument("delay")
p.add_argument("pair", nargs="?", default="4i")
p.add_argument("readiness", nargs="?", default="blocked")
a = p.parse_args()
if a.outcome and a.calibration:
    p.error("outcome mode cannot run calibration")
# sockaddr_un.sun_path holds 108 bytes, and the evidence log path is longer, so the
# QMP socket lives in the container-local /tmp under a unique name.
qmp_path = f"/tmp/wr-{uuid.uuid4().hex}.qmp"
command = ["qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-machine", "q35",
           "-smp", "2", "-m", "2G", "-display", "none", "-serial", "stdio",
           "-monitor", "none", "-qmp", f"unix:{qmp_path},server=on,wait=off",
           "-no-reboot", "-nic", "none", "-kernel", a.kernel, "-initrd", a.initramfs,
           "-append", f"earlycon console=ttyS0 loglevel=error rdinit=/init -- {a.scenario} {a.value} {a.delay} {a.pair} {a.readiness}" + (" --outcome" if a.outcome else "")]
a.log.with_suffix(".command.json").write_text(json.dumps(command, indent=2) + "\n")
marker = b"WR_OUTCOME_COMPLETE" if a.outcome else (b"WR_CALIBRATION_COMPLETE" if a.calibration else b"WR_COMPLETE")
started = time.monotonic()
process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
matched = False
guest_nproc = None
qmp_stopped = False
try:
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    tail = b""
    with a.log.open("wb") as log:
        while time.monotonic() - started < 110:
            for key, _ in selector.select(timeout=1):
                block = key.fileobj.read1(65536)
                if not block:
                    raise RuntimeError(f"QEMU exited before {marker.decode()}")
                log.write(block)
                log.flush()
                tail = (tail + block)[-65536:]
                if marker in tail:
                    matched = True
                    break
            if matched:
                break
        if not matched:
            raise TimeoutError("guest fixture did not complete within 110 seconds")
    counts = [int(line.split()[1]) for line in a.log.read_text().replace("\r", "").splitlines()
              if line.startswith("WR_GUEST_NPROC ")]
    if len(counts) != 1:
        raise RuntimeError("missing or duplicate guest nproc evidence")
    guest_nproc = counts[0]
    if guest_nproc != int(command[command.index("-smp") + 1]):
        raise RuntimeError("guest nproc does not match boot -smp")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as qmp:
        qmp.settimeout(5)
        qmp.connect(qmp_path)
        qmp.recv(65536)
        qmp.sendall(b'{"execute":"qmp_capabilities"}\r\n')
        qmp.recv(65536)
        qmp.sendall(b'{"execute":"quit"}\r\n')
    process.wait(timeout=5)
    qmp_stopped = True
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    Path(qmp_path).unlink(missing_ok=True)
    a.log.with_suffix(".outcome.json").write_text(json.dumps({
        "fixture_complete": matched, "qemu_returncode": process.returncode,
        "qmp_path": qmp_path, "guest_nproc": guest_nproc, "boot_smp": int(command[command.index("-smp") + 1]),
        "elapsed_seconds": time.monotonic() - started,
        "termination": "QMP quit after fixture completion" if qmp_stopped else "incomplete execution",
    }, indent=2) + "\n")
