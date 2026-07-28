# OpenCBDC 2PC run 20260722-174240-2125

## Reviewed result

The independent second review records:

- **1 new bug, Medium:** an asynchronous coordinator RPC can remain unresolved after a successful send followed by a disconnect.
- **1 known open bug, Minor:** coordinator and locking-shard Raft snapshots are disabled, preventing automatic log compaction.

Read [independent-review.md](review/independent-review.md) for the source evidence, focused runtime reproduction, and disposition of all seven original candidates.

## Important correction

The archived pipeline's [confirmed-bugs.md](confirmed-bugs.md) is preserved as original run evidence, but its final conclusion is superseded by the independent review. In particular, the pipeline counted CR-1 as reproduced; the second review rejected CR-1 because its harness directly constructed an invalid phase sequence without exercising the real coordinator, Raft, or recovery path. The new bug recorded here is a narrowed mechanism adjacent to the archived MC-2 candidate.

## Provenance

- Source archive: `opencbdc-tx.tar`
- Archive SHA-256: `daedbc09bf020065c4c810d90f66c765bd532862854185e56ca836a93a8671ad`
- Archive size: 115,752,182 bytes
- Archive inventory: 85,683 entries, approximately 4.004 GiB expanded
- Archived run ID: `20260722-174240-2125`
- Independent source review: [`mit-dci/opencbdc-tx@8444ef8b4297c85109b4681071a8c43c5fea329b`](https://github.com/mit-dci/opencbdc-tx/tree/8444ef8b4297c85109b4681071a8c43c5fea329b)

The archive does not contain a complete source tree or a verifiable source commit. The independent review commit above is therefore separate provenance and is not presented as the archived run's target revision.

## Included evidence

This record retains 44 small original files: the top-level reports, core TLA+ specifications and hunt configurations, the source-level harness, and source reproducers. It also adds the independent review and its focused RPC reproduction.

The raw archive is not committed because it exceeds GitHub's 100 MiB per-file limit. Generated TLC output, state directories, compiled binaries, agent traces, logs, prompts, session metadata, and temporary worktrees are excluded. The archive hash and [.record metadata](.record/manifest.json) preserve the source reference and curation boundary.
