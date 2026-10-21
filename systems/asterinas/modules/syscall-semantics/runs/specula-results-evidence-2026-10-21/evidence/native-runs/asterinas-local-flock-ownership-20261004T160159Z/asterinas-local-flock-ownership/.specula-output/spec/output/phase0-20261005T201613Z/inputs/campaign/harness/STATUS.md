# Harness generation status

Status is **INCOMPLETE**. The reviewed v12 harness is ready for its next bounded run, but host `MemAvailable` is 9,176,896 KiB, below the required 10,485,760 KiB build admission threshold. The admission check stopped before the v12 build or guest. Do not lower that threshold or the trace-quality check to obtain a pass.

The completed v10 run produced 16 real Asterinas traces with 1,457 events. All 49 specified event types were exercised, every buffer reported zero dropped events, and all 16 traces obtained a complete TLC witness with the original base guards, enabled invariants and exact post-state equality. C06 and C11 are explicitly incomplete runtime prefixes. Their accepted replay does not claim that the pending syscalls completed or that a watchdog confirmed a defect.

The maximum observed cross-thread interval overlap was 9/6,916, below the installed Category B guide's 20 percent requirement. The current v12 adds C00-open-overlap to exercise real open entry while another insertion holds the original FD-table guard. It also adds C13-open-close to observe the original open reference after descriptor removal. Those two cases are **NOT_RUN**. Current source and harness files are v12, while the existing runtime traces were produced by v10. The model and TraceSpec did not change.

Independent corrective reviews closed R1-R8 for the exact v12 inputs. Review identity, hashes, material findings and dispositions are in `evidence/review-v12.md` and the preceding review chain. `evidence/runtime-reviewed.sha256` binds the approved harness plus the model, Trace configuration, instrumentation contract and acceptance adapter. No corrected verification ran while an applicable review finding was open.

The real v10 guest reported two CPUs and ramfs magic `0x858458f6`. Its `Linux 5.13.0` uname string is Asterinas's compatibility identity, not execution of a Linux 5.13 kernel. Source/build hashes identify the actual Asterinas image. Linux C01-C05 controls completed with zero failures on the host's Linux 7.2.8 in a separate tmpfs. No fixed Linux v6.16.5 kernel was built or booted.

`status.json` binds every accepted trace to its SHA-256, raw manifest, buffer counts and preserved validation log. The successful runtime attempt is `evidence/attempt-20261005T140700-085490617/`. Earlier setup failures, the BIOS/EFI mismatch timeout, and the missing early-console attempt remain separate evidence and are not protocol findings.

Use [RESUME.md](RESUME.md) for the continuation command and remaining checks. Bug confirmation, severity classification, repair, upstream submission and Git commits were not performed.
