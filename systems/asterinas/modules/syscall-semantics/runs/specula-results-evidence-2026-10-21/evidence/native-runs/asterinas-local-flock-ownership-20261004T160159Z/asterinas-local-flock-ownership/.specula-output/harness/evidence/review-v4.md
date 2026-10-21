# Independent corrective review of flock harness v4

Verdict: **PASS for the exact v4 revision**. The ambiguous alloc-source replacement is corrected, and the earlier installed-hook version caveat is closed. R1-R4 remain closed. The controller may resume the bounded build under the existing resource policy and updated exact-version marker. This is a static corrective-review verdict, not a successful build or runtime result.

Reviewer: `/root/harness_review`, independent from the harness author. Date: 2026-10-05T13:25:44.023423+00:00.

Reviewed inputs are `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v4/inputs`, `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v4/sha256.json`, `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v4/revision.diff` and `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v4/reason.md`. Only `src/patch_alloc.py` differs from the reviewed v3 manifest. Each v4 snapshot file was hashed and compared with its manifest. The reviewer changed no source/harness file, ran no target build, guest, tests, controls, TLC or trace replay, and acquired no locks.

## Trigger and correction

The triggering log is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/attempt-20261005T132307-072934316/build.log`, SHA-256 `e508a224caca339cfd200bebe8af42b078ce66d866c05c5b1daf6232fa47685b`. It records the replacement-count assertion finding two copies of `ptr::drop_in_place(&mut (*self.ptr.as_ptr()).data)`. This is a harness application failure before compilation. The prior script changed only its in-memory string before this assertion, so this failure did not write a partially patched sysroot file.

The reviewer inspected the pinned original alloc source. One occurrence is in `Arc::drop_slow` at lines 2142-2143, preceded by the comment stating that `self.alloc` is borrowed. The other is in `UniqueArc::drop` at line 4940. V4 matches the Arc-specific preceding comment and the statement together. The completion callback therefore applies to the intended Arc payload cleanup, while leaving UniqueArc unchanged. The count assertion remains in place.

The token ABI and actual clone, put and upgrade primitives are unchanged from v3. Stable OFD identity is still captured before each relevant primitive, actual primitive outcomes are still passed to the observer, and final cleanup still runs synchronously. No reference, lock boundary, model, invariant, trace adapter, or scenario semantics changes in this correction.

## Installed-source check

The marker-only early return is removed. V4 obtains the original source either directly from the installed file with the pinned original hash or from a retained original file whose bytes have that hash. It derives the exact expected instrumented source from that original. Before writing the sysroot, it requires the installed source to equal either the pinned original or the newly derived instrumented source. A prior address-ABI patch, a different token-hook revision, or unrelated edits are rejected rather than silently accepted.

The original evidence and instrumented evidence files are written only after the replacements and installed-source comparison succeed. The installed source is written only when it differs from this exact expected instrumented source. This permits the unchanged v4 rerun and rejects an incompatible prepatched sysroot. The exact original-source pin remains `2e11d0c0eb5ebabdbb3d045ed5b241869feeacff6eae9a8869bf48ebcf87eef1`.

No remaining material finding was identified in this focused correction. Compilation, actual installation of the corrected private alloc hooks, target boot, Linux controls, event coverage, clock/concurrency evidence and trace replay remain execution obligations. The controller must renew `runtime-reviewed.sha256` with v4's `patch_alloc.py` hash and retain the unchanged companion model/contract/adapter hashes recorded in review-v3.md.

## Exact reviewed hashes

Paths below are relative to `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v4/inputs`.

| File | SHA-256 |
|---|---|
| `apply.sh` | `43cd880d879a363e19e68345b0aef97bfde05042345a946e6434d069ae8621eb` |
| `clean.sh` | `241a1c260c373dd47b78cd90e90e3d2933232e44f0d9c9f6c5c6a138de3f3ce1` |
| `patches/instrumentation.patch` | `94e0cb45b91a486426a18b65e8cd6fe0d1d8ff6565bc5cb69d51bd251968bf5b` |
| `run.sh` | `c7daecf41da0006feed78f2be9e27a227a683a0904c54ab6a8b941496e52cca4` |
| `src/build.sh` | `5e3434c4846824e5bf92edb1f694fa1aebfab0d21cb7bd030e6d64e6ee643224` |
| `src/check_traces.py` | `bb7dafe83fac86d4f6d35a13ff7fb7adf55591d5af1dcabf34eba7bd10922916` |
| `src/collect.py` | `cec1b4010e2bdf6f1241b7fdc23aa9a1c3db0ac43eb84878104ea0e960b21ef7` |
| `src/flock_trace.rs` | `07aed7b615e1e92086b7f5e300ce3a657268f59d38353a56a306b44c9f24ea8b` |
| `src/patch_alloc.py` | `8e5731c073ffb823ba3c119dfa56d2dbe884dd57b80da30daedfea6347a5dda9` |
| `src/run_case.sh` | `fe1c910f7ac49aa5b5d8fbbc5464f27b97aff52f9241dc53f36e3a4dcdf8942d` |
| `src/scenarios.c` | `8948cff1f7a31cbd5e1295651d0f35f8dccc2d0a85ab2ba983e4780966d68be1` |
