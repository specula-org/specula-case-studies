# Compiled instrumentation audit

The audit uses the kernel ELF with SHA-256
`ef6d75a71f066985b9d668e6831d9bd4f95a406a57dfc1b2add4381e0ed0b32a`,
which the successful guest attempt `20261005T220019Z` booted. Symbol addresses
and sizes are retained in `compiled-hook-symbols.json`. The selected functions
are retained in full in `compiled-hooks.txt`.

- `scm_trace::stamp` calls MFENCE, `IoMem::read_once::<u64>` at offset
  `0xf0`, and MFENCE in that order. The reader at `ffffffff8848c62c` performs
  one 64-bit load from the mapped address. There is no tracing lock or software
  sequence counter in this read path.
- `scm_trace::release` decrements the original Arc at `ffffffff88213717`,
  calls its slow destructor when needed, then reads the end timestamp and
  emits the release event. The observer does not retain another Arc.
- `sys_close` calls the complete `ClosedFile` drop glue at
  `ffffffff88283e42` before the end timestamp at `ffffffff88283e47`.
  This observes field destruction as well as the custom destructor body.
- The successful `sys_recvmsg` path calls the `MessageHeader` drop glue at
  `ffffffff881f23a9`. Its exit path reaches the completion observer at
  `ffffffff881f1abe` afterward. The header drop glue invokes the file-message
  destructor, which calls the per-reference release observer.
- The ancillary writer inserts the entry at `ffffffff882748ef`. It emits
  the insertion while holding the existing table guard, releases that guard
  at `ffffffff88274ab9`, then performs the integer copy at
  `ffffffff88274b6d`. The hook preserves the installation/publication window.

Source readback also checked the queue acquisition markers, snapshots taken
under the queue guard, unlock boundaries, PEEK clone versus ordinary move,
writer rewind and explicit file-table borrow release. All 34 event names and
all 34 receiver fields have mandatory post-state checks. The source and
instrumentation patch were unchanged during this validation attempt.

The 23 guest fixtures each passed 128 cross-CPU clock exchanges. This is
qualification for the recorded guest run, not a general hardware proof.
Uncached HPET reads have measurement overhead and can change scheduling.
The actual intervals and overlap counts are retained without adjustment.
