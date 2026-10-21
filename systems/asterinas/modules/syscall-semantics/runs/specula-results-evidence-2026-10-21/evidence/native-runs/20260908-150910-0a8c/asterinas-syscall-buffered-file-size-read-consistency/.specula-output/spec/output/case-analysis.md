## Counterexample classification

Implementation source was checked before each classification. All 18 BFS violations map to Case C; the only Case B-equivalent correction was the trace-driven VMO batch model correction before convergence. No outcome invariant was revised.

| Finding | Required condition | Implementation check | Evidence limit |
|---|---|---|---|
| MC-1 | EOF sampled before a competing cache mutation | ramfs size() drops metadata guard before cache acquisition; resize and write acquire cache first | Growth under-reporting also appears in immutable guest receipts |
| MC-2 | C grows while L stays old, then a reader acquires U | exFAT preparation releases W and filesystem mutex before copy; read does not limit its writer | Exact interleaving is model/source evidence |
| MC-3 | A later preparation or shrink invalidates an earlier candidate | exFAT reacquires U without revalidating C/A or recomputing candidate; VMO zero clamp is successful | No whole-call snapshot assumption; later read continuation is source-derived |
| MC-4 | An isolated successful resize does not set target L | Public resize has no extension cache update or unconditional logical-size assignment | Both directions independently observed in exfat-0-10 guest trace |
| MC-5 | Freed subject clusters retain nonzero bytes and are reused | fat.rs allocation searches from EXFAT_FIRST_CLUSTER; allocation/free only changes bitmap/FAT, and the aligned overwrite avoids backend read | Physical reuse not recorded by current guest fixture |
| MC-6 | Zero-length ramfs write at an offset beyond L enters preparation | No empty-reader return before offset+length and size publication | Beyond-EOF empty-write witness remains unconfirmed in guest |
| MC-7 | Zero-length exFAT write at an offset beyond L enters preparation | No empty-reader return before allocation/cache growth and saved-size publication | Beyond-EOF empty-write witness remains unconfirmed in guest |
| MC-8 | Entire source remains inaccessible but numeric range is valid | VmSpace::reader checks address bounds, not mapping readability; ramfs publishes before fallible copy | Linux v6.12 zero-progress-at-EOF comparison only; no universal error rollback |
