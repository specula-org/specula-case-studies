# CloudNativePG

## Scope

Specula studied [CloudNativePG](https://github.com/cloudnative-pg/cloudnative-pg)
primary leases, automated failover, synchronous replication configuration, and
the consistency of quorum metadata observed by the operator. The source revision
was [d5f3426e161076322086b58c886cf8e7435f0e1b](https://github.com/cloudnative-pg/cloudnative-pg/tree/d5f3426e161076322086b58c886cf8e7435f0e1b).

## Bugs

The reviewed run contributes **1 new reproduced bug: CR-4**.
It is a code-review finding with an archived live-cluster reproduction, not a
TLC counterexample. Internal reproduction is not upstream maintainer confirmation.

| Reference | Component | Finding | Reproduction evidence |
| --- | --- | --- | --- |
| CR-4 | Failover quorum | Stale FailoverQuorum cache data can authorize promotion of a replica missing an acknowledged transaction after the synchronous quorum is reduced. | A real CloudNativePG 1.30.0 controller uses cached W=2 while PostgreSQL and the live API use W=1. After the primary and its sole acknowledger fail, the controller promotes the remaining stale replica; a SQL query returns no row for the transaction whose commit succeeded. |

The [reviewed report](modules/primary-failover/runs/cnpg-primary-failover-gpt6-astra-xhigh-p4-20g-20260907/confirmed-bugs.md)
describes the trigger, source audit, and assurance limits.
The recorded test uses controlled node failures and withholding of one real
Kubernetes watch. It does not inject a fabricated quorum object or patch product
logic. The affected quorum paths match the pinned source revision.

## Evidence

- [Run record](modules/primary-failover/runs/cnpg-primary-failover-gpt6-astra-xhigh-p4-20g-20260907/README.md)
- [Reproduction instructions](modules/primary-failover/runs/cnpg-primary-failover-gpt6-astra-xhigh-p4-20g-20260907/repro/README.md)
- [Other candidate dispositions](modules/primary-failover/runs/cnpg-primary-failover-gpt6-astra-xhigh-p4-20g-20260907/review/decisions.md)
- [Model and trace-validation scope](modules/primary-failover/runs/cnpg-primary-failover-gpt6-astra-xhigh-p4-20g-20260907/spec/README.md)

The other four candidates match existing upstream reports and are excluded from
the bug count. TLC produced no counterexample; its searches were time-limited.
The passing implementation traces exercise the lease component, not the
configuration/quorum/promotion path that reproduces CR-4.
