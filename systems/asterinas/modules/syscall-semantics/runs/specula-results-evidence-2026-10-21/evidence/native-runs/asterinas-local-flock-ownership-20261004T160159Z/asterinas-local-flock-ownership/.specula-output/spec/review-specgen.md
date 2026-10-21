# Spec Generation Review: asterinas-local-flock-ownership

The revised specifications cover all five scenarios and resolve the six previous review findings. No remaining material correctness or coverage issue was found. This verdict concerns spec generation within the brief's stated scope. It does not establish runtime convergence or confirm an Asterinas defect.

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All five scenarios have extensions and targeting hunts. C01–C12 cover aliases, conversions, registration timing, blocker migration, close lifetimes, temporary last references and negative controls. C10 now includes the independent post-cleanup probe. |
| Action Design | 5/5 | The 49 implementation-named actions preserve the relevant divergent paths and interleaving boundaries. Open-local references survive insertion. Capture, registration, notification, parking, reference puts and synchronous destruction remain distinct. |
| Source Annotations | 5/5 | Implementation transitions and source-derived helpers cite the relevant file and line ranges. The checked references cover the syscall callers, flock list, FD table, Arc/Weak primitives and scheduler bridge. Ghost bookkeeping and fixture assumptions are identified separately. |
| Invariant Coverage | 5/5 | All ten brief section 5 obligations are enabled in targeting hunts. ControlResults checks C01–C03 and C10 returns. C09 preserves safety checks and explicitly excludes the unsupported completion claim associated with FL-CR-1. |
| MC Spec Structure | 5/5 | Only new caller admissions are counter-bounded, as the brief's finite fixtures permit. Reactive work is unbounded. General safety uses thread symmetry, while named-role and temporal hunts omit it. Keeping counters in the fingerprint and omitting VIEW or queue-capacity constraints avoids dropping behavior. |
| Trace Spec Design | 5/5 | Every event invokes the full base action and exact post-state validation. There are no silent actions. Per-thread timeboxes preserve partial ordering. TraceNoWitness and the supplied adapter implement acceptance of one complete matching interleaving. |
| Instrumentation Mapping | 5/5 | All 49 base actions have exactly one dispatch case and mapping row. Hooks specify source locations, timing, arguments and required fields. Reference counts must come from primitive outcomes, and logging must not retain extra owner references. |
| Logical Correctness | 5/5 | Source comparison and parser checks found no remaining erroneous guards, tautological target obligations or temporal-property mismatch. The Linux conversion oracle remains separate from Asterinas behavior. Recursive cleanup follows from the actual last reference drop. |

## Overall: 40/40

## Issues Found

- No material issues remain in the reviewed revision.

The previous findings were rechecked against the current files:

| Previous finding | Disposition and evidence |
|------------------|--------------------------|
| R1: Open-local reference was omitted. | Resolved. `base.tla:107–124` clones at insertion, retains `pending`, puts the original reference and then returns. `MC.tla:259–261` counts completion at that return. This matches `syscall/open.rs:54–67`. |
| R2: Syscall entry incorrectly required a free table guard. | Resolved. `SysOpen` and `SysFlock` have no table-lock guard. Lookup and table mutations retain serialization. Borrowed-table exclusivity is a separate assumption at `base.tla:10–12`. |
| R3: A losing candidate serialization rejected a valid trace. | Resolved. `Trace.tla:173–184` searches for complete consumption. `Trace.cfg:16–30` and `generation-checks/validate_trace.py:35–48` distinguish a matching witness, exhausted search and execution errors. |
| R4: C09 asserted unsupported completion. | Resolved. `MC_hunt_3_wake_race.cfg` retains its safety obligations without FixtureCompletes. The repeated drain/re-enqueue behavior remains enabled and is explained in `brief-coverage.md:24–33`. |
| R5: Positive controls omitted distinguishing outcomes. | Resolved. `MC.tla:284–293` checks each relevant return before it can be overwritten. The C01, C02 and C03 configurations enable ControlResults. |
| R6: C10 omitted the final independent probe. | Resolved. `MC.tla:130–138` opens C and probes after B's captured syscall returns. The C10 configuration supplies the additional admissions and enables ControlResults. |

## Review Evidence and Limits

This review independently checked the source checkout at commit `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. The checkout is clean. The Linux oracle was compared with the supplied local Linux v6.16.5 `fs/locks.c:1096–1137`. Arc destruction and upgrade were checked against the installed `nightly-2026-07-21` source.

Fresh SANY parsing, semantic processing and linting succeeded for all three modules with a 512 MiB heap. TLC's configuration parser successfully parsed all 19 configurations. Independent enumeration found 49 base actions, 49 trace dispatch cases and 49 instrumentation rows, with no differences. Every proposed obligation has an enabled hunt entry. Fresh parser logs and the input snapshot are retained under `/tmp/flock-specgen-review-yzm9p7xz/`.

The supplied revision logs were inspected, and the current specifications/configurations match their originating revision workspace byte for byte. Those existing logs record four accepted synthetic traces and three rejected negative controls. They also record 13 hunts completing without violations, C05 violating ConversionOracle, C06 violating ConvertersDrain, and C11 violating NoRecursiveListWait. These counterexamples target the brief's source questions and are not spec-generation failures. C11 stopped on its safety violation before establishing a separate FinalReleaseCompletes result. The general MC run timed out and remains incomplete.

No TLC exploration, trace replay, Linux control or Asterinas execution was launched by this review. Synthetic fixtures do not establish implementation fidelity under runtime concurrency. Actual instrumentation must still obtain the specified primitive outcomes without adding references or changing cleanup ordering. Trace validation must use the documented adapter: raw TLC exit 12 for TraceNoWitness means a matching witness, while exhaustive exit 0 means no witness. The stock raw-output success parser has different semantics.

All 82 entries in the supplied SHA-256 manifest matched before this report was replaced. That manifest includes the superseded review, so its review entry is historical after this write. The reviewed input hashes below remain unchanged. No specification, configuration, instrumentation instruction or source file was modified.

| Input | Reviewed SHA-256 |
|-------|-----------------|
| `base.tla` | `5114e9f43633ca283e41fec12ecd9774aef8c0f2bf89e45008834a06f71dfc08` |
| `base.cfg` | `9d9087afee50d9d849ce96d49e9af12d1c33fa46a84a3eb5a89300c57983d183` |
| `MC.tla` | `f11ba301eb105f864f91f4b88889e4df9e2b4e60316469f61ca3deec0855c530` |
| `MC.cfg` | `b708e3af679222ac9018e18e0468c600fe67ff33b706f1eb2d5dc9a8f69ed548` |
| `Trace.tla` | `918b7c4afe353cf32e50bc01c598b621d7ffd667b4e8ff835d4ba78716c17abf` |
| `Trace.cfg` | `a3b384f0dd0c4155222692134581790b0f7097fbebb54c160bc24f114398a140` |
| `instrumentation-spec.md` | `beeec7c8d523d76299bee5beb9f136919465cffba680d716db95023217581f72` |
| `../modeling-brief.md` | `6b937de72bafad949007b37e526819b230a243fd25014600f8ce1263c7472c38` |

## Verdict: PASS
