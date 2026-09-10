# Reviewed Confirmation Report: CloudNativePG

## Result

Accepted bugs: **1 NEW**, source **Code Review**, reference **CR-4**.
Model-checking discoveries: **0**. Four other candidates are excluded; see the
[disposition ledger](review/decisions.md).

## CR-4: Stale Quorum Evidence Can Lose an Acknowledged Transaction

- Status: REPRODUCED in the archived 2026-09-08 live-cluster execution.
- Novelty: NEW under the reviewed prior-report search; subject to upstream deduplication.
- Upstream confirmation: not established by this record.
- Source revision: d5f3426e161076322086b58c886cf8e7435f0e1b.
- Runtime: published CloudNativePG 1.30.0 and PostgreSQL 18.6.

### Impact

The operator can promote a replica without a transaction that the old primary
already acknowledged to a client. The transaction remains absent on the new
writable timeline rather than being recovered when quorum metadata catches up.

### Trigger

1. Run three database instances with required synchronous replication and failover quorum enabled.
2. Establish the real operator watch and verify that W=1 correctly denies failover when only one replica remains available.
3. Restore the nodes and deliver a genuine W=2 FailoverQuorum observation.
4. Withhold subsequent events on that established watch, then normally update the Cluster configuration back to W=1.
5. Disconnect one replica and commit a transaction acknowledged by the other replica.
6. Fail the primary and the acknowledging replica, leaving only the stale replica available.
7. The operator uses cached W=2 in R+W>N, authorizes promotion, and the new primary returns zero rows for the acknowledged transaction.

The test uses real APIs and PostgreSQL processes. Node pause/stop and Pod
deletion establish the fault scenario. The watch proxy withholds real events; it
does not manufacture quorum status.

### Source Mechanism

The operator reads FailoverQuorum through its cached client at
[replicas_quorum.go:48](https://github.com/cloudnative-pg/cloudnative-pg/blob/d5f3426e161076322086b58c886cf8e7435f0e1b/internal/controller/replicas_quorum.go#L48)
and evaluates R+W>N at
[replicas_quorum.go:117](https://github.com/cloudnative-pg/cloudnative-pg/blob/d5f3426e161076322086b58c886cf8e7435f0e1b/internal/controller/replicas_quorum.go#L117).
The instance manager resets status before reload and republishes it afterward,
but these writes do not wait for the operator's independent cache to observe the
reset. A previously positive W can therefore be stale-high.

The release and pinned source have byte-identical replicas_quorum.go,
replicas.go, and instance_sync.go. The instance_controller.go difference affects
failure-domain handling, not the reset/reload/publication sequence or the test's
configuration.

### Reproduction Evidence

The [archived output](confirmation/CR-4/reproduction-output.log) records:

| Observation | Result |
| --- | --- |
| Safe control, R=1/W=1/N=2 | isStronglyConsistent=false |
| Runtime and live API after configuration update | W=1 |
| Last delivered operator quorum event | W=2, resourceVersion=1749 |
| Withheld later quorum event | W=1, resourceVersion=1757 |
| Client commit | returned successfully |
| Old primary and acknowledging replica | row count 1 |
| Promotion decision | R=1/W=2/N=2, isStronglyConsistent=true |
| New primary cr4-3 | writable; acknowledged row count 0 |

Use the [reproduction instructions](repro/README.md) to repeat the archived test.

### Assurance Limits

- The live-cluster reproduction is archived evidence, not a new execution performed during case-study preparation.
- The proxy drops withheld watch events rather than buffering and later releasing them. Its finite observed prefix models delayed delivery; no general eventual-delivery guarantee is claimed.
- The standalone test proves the missing acknowledged row after promotion. Follow-up notes from the original run describe persistence after restoring failed nodes, but that restoration is not an assertion in the standalone script.
- The image tag is the archived runtime version, not a claim that the test compiled the pinned source or verified an immutable container digest.
- Passing lease traces and time-limited TLC searches do not validate this configuration-change/failover path.
