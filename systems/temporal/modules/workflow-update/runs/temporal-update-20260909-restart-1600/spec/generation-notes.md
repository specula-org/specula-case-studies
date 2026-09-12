# Generation boundary and provenance

Category A (Distributed / Message-Passing), established before writing the specification. Methodology: `/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/Specula/skills/spec_generation/SKILL.md`, `guide.md`, all five referenced methodology documents, and the worked example; single agent, sequential phases. The guide makes `brief-coverage.md` mandatory; the older checklist wording calling the checklist optional does not remove that output requirement.

Production source HEAD verified as `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Six preexisting untracked analysis test files are preserved. No production changes are part of this phase. Source annotations use line numbers verified against this checkout, including event-cache insertion at `mutable_state_impl.go:5900`.

One namespace, Workflow ID and Run ID, two independently moving History hosts, one active Workflow lease, and at most one outstanding execution transaction. Host changes preserve a host cache; process restart clears it. Single-cluster failover version is fixed and distinct from the shard range and record version. Cache keys contain namespace, workflow, run, event ID and event version; neither Update ID nor shard range is part of the key.

Current default cache settings inspected in `common/dynamicconfig/constants.go:1944-1962`: host cache enabled, 256 MiB host / 512 KiB shard capacity, one-hour TTL. The model uses an explicit host-versus-shard cache-lifetime switch and eviction action, not a capacity/TTL timing proof. No deployment configuration was supplied: these are source defaults, not claimed live service settings. Pausing, worker build-ID changes, CHASM callbacks/transport and cross-run transitions are excluded. Callback attachment while Sent is retained as the small discriminator requested by Scenario 4.

Review handoff incorporated: outcome consistency also covers persisted worker-handler failure payloads, separately from rejection and synthetic workflow-close failure. Brief safety properties retain their original meaning. CR-5 is represented without assuming a persisted close before its early abort. CR-6 is represented by conditional timer-object validation; exact deadline timing remains a component/public-handler reproduction task, not an invented timing invariant.

Generation checks and coverage status will be recorded separately. No existing analysis test or review result is counted as a new MC discovery or as implementation trace validation.

`HostCacheEnabled=FALSE` models a newly constructed shard-level cache after acquisition; it does not turn off cache reads. All primary configs retain the pinned default TRUE. Generated task clock checks are scoped to a single run without Mutable State rebuild/refresh, as documented in the instrumentation handoff.
