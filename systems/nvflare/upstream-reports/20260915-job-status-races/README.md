# NVFlare Job Status Race Reproducers

These reproducers were prepared for two NVFlare job lifecycle issue reports.
They were tested against NVFlare main at `5f09f3b4ddd5212093a8b78749d19bf21a8b4f4f`.

Run from a current NVFlare checkout:

```bash
PYTHONPATH=/path/to/nvflare timeout 60s python repro_pre_run_abort.py
PYTHONPATH=/path/to/nvflare timeout 60s python repro_terminal_status.py
```

The scripts use NVFlare's real `JobRunner`, `JobCommandModule`, `SimpleJobDefManager`,
`FilesystemStorage`, `Workspace`, and the public `Session.monitor_job_and_return_job_meta`
logic. They substitute the external client transport and server app process with a small
`ServerEngineSpec` test double so the race order can be made deterministic in one process.
