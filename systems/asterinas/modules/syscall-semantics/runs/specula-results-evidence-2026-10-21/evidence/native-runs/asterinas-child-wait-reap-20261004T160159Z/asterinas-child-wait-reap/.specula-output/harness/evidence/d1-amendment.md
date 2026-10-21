# Candidate v5 amendment D1: Docker daemon

Author: lane controller (Claude), 2026-10-06. Trigger: execution attempt 2
(`evidence/20261005T211706Z-2677310-0a5f816f71434f1396d34bf8c0fc83ec`) failed with
`Error response from daemon: No such image: sha256:897cb1b3…`. `run.sh` addressed the rootful
daemon at `/var/run/docker.sock` through `sudo -n`, which only holds
`asterinas/kernel-dev:0.18.1-20260926`. The pinned `asterinas/dev:0.18.1-20260926`
(`897cb1b3…`) and the lane preflight's image, KVM and SMP checks belong to the user's rootless
daemon at `unix:///run/user/1000/docker.sock`, which also delegates cpu, io, memory and pids
cgroup controllers and passed `/dev/kvm` to the memfd harness container.

Change: `docker_cmd` in `run.sh` (and its frozen copy) now addresses the rootless socket without
`sudo`. `candidate-v5/hashes.json` was regenerated for that one file. Nothing else changed.
The author does not approve this change; it needs independent re-review before execution.
