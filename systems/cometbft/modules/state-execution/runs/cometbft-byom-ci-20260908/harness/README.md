# CometBFT BYOM trace harness

From the target `.specula-output/` directory, run:

```bash
bash harness/run.sh
```

By default, the script makes a disposable writable clone of the sibling
`source/` checkout, applies `patches/instrumentation.patch`, and runs six real
Go scenarios with a ten-minute outer timeout per command. It checks that every
NDJSON file is nonempty and structurally valid, writes traces under `traces/`,
and preserves test logs under `spec/output/`. The immutable source checkout is
not modified.

Set `SPECULA_SOURCE` to select a different immutable source checkout, or set
`SPECULA_WORK_SOURCE` to use an existing writable checkout. Optional
`SPECULA_TRACE_DIR` and `SPECULA_HARNESS_LOG_DIR` overrides are useful for a
diagnostic run that should not replace the retained traces.
