# Reproduce CR-4

Use a disposable Linux host with Docker, Kind, kubectl, OpenSSL, Python 3,
Git, GNU timeout, network access, and capacity for a four-node Kind cluster.
The experiment creates and destroys its own cluster, pauses/stops database
nodes, deletes test Pods, and temporarily withholds quorum watch events.

Run from this directory:

```sh
timeout --kill-after=30s 45m python3 run.py --execute
```

Optional: use an existing clean source revision from a local Git repository
without modifying its checkout:

```sh
timeout --kill-after=30s 45m python3 run.py --execute --source-repo /path/to/cloudnative-pg
```

The launcher fetches only revision d5f3426e161076322086b58c886cf8e7435f0e1b into
a temporary checkout, isolates KUBECONFIG, and gives all test containers and the
Kind cluster unique names. It invokes the original test with only source paths
and disposable resource names changed. Product logic, the fault sequence, and
assertions are unchanged. Without --execute it prints usage and does nothing.

Exit 0 means the test observed its expected bug behavior: a commit succeeded
under W=1, the controller authorized promotion using stale W=2, and the new
primary returned no row. Setup failures and missing assertions are nonzero.

The [original test](test_bugCR-4_stale_quorum_watch.py) is preserved byte-for-byte.
Do not invoke it directly on a shared Docker host: it deletes fixed resource
names before starting. The wrapper avoids those names and always attempts
cleanup. Forced SIGKILL or host failure can still leave resources; the launcher
prints their unique names for manual inspection.

The [captured result](../confirmation/CR-4/reproduction-output.log) comes from
the original run using published CloudNativePG 1.30.0 and PostgreSQL 18.6 images.
This packaging step did not rerun the live cluster. Image tags may change;
immutable image digests were not included in the archive. The proxy withholds
events rather than replaying them after unfreeze; the result establishes the
observed stale-cache prefix, not arbitrary watch behavior.
