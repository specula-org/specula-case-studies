# Model design record

Category A, determined before writing TLA+. Revision: temporalio/temporal@0c010ce5fe8c0180aa7573c72fe8fc87c6df7025. Backend: SQL / SQLite WAL; atomic logical workflow-and-task mutation, RangeID conditional workflow/shard writes, unfenced immediate range deletion with the actual `[min,max)` SQL predicate.

Generation follows the user-supplied `spec_generation/SKILL.md`, full `guide.md`, and all five methodology references. The guide's mandatory Phase 2.5 audit takes precedence over the checklist's older optional wording. Single agent; sequential file-producing phases.

The source checkout has four pre-existing untracked investigation tests; this task leaves them intact. This output is specification generation and executable model checks. Native reproduction and implementation trace validation require the next harness/validation phase.

Design: bounded task identities, two owner instances, separate owner epochs, two ordered readers, predicate-bearing slices and explicit iterator intervals, executable identities distinct from task keys, checkpoint program counters, separate deletion/store/reply and shard-snapshot/store/reply transitions. Ordinary RPC delivery may duplicate. Allocation and persistence outcomes retain uncertain completion. A stable healthy shard is never reloaded by a fairness assumption.

Generation completed with base/MC/Trace configurations, nine hunt configurations, mandatory brief audit, and all 65 instrumentation mappings. `checks/validation.md` records the completed one-task exhaustive bound, six explicit composition/control schedules, seven negative controls and the exact evidence limits. LiveCursorSoundness remains a known-failure diagnostic; no automatically scheduled reload hides CR-1. Source-derived model repairs and the superseded incomplete run are preserved in the validation record.
