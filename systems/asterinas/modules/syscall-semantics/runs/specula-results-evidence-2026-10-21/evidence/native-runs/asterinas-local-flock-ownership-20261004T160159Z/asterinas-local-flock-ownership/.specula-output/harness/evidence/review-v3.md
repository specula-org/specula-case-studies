# Independent corrective review of flock harness v3

Verdict: **PASS for this exact bounded harness revision and the recorded pristine private alloc input**. R1-R4 are closed by source review. This closes the corrective review gate for the controller to begin the bounded modified-kernel build and subsequent declared cases. It is not a passing build, trace validation, runtime campaign, or defect-confirmation result.

Reviewer: `/root/harness_review`, independent from the harness author. Date: 2026-10-05T13:22:19.976370+00:00.

The reviewed immutable input is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v3/inputs`. The review includes `sha256.json`, `revision.diff`, and `reason.md` in the same revision directory, with unchanged material carried forward from the prior reviews. The baseline is `0c60537098f4c2949ad2d382aaf499de72263d76`. All hashes in the table below were read and checked against the recorded exact versions. The reviewer made no source/harness changes, ran no build, guest, Linux control, test, TLC or trace replay, and acquired no locks.

## Finding dispositions

| Finding | Disposition | Evidence |
|---|---|---|
| R1, release intervals miss real unlock | CLOSED | The v2 table-release timestamp and scheduler pre-dequeue/pre-abort timestamps are unchanged. Each relevant release lies within its event interval. |
| R2, reused address matches a dead OFD | CLOSED | Active owner registration still retires only after the actual payload cleanup returns. Historical scalar identity data remains exportable. |
| R3, C08 accepts a stale park marker | CLOSED | The event-index boundary publication and fresh-park comparison remain unchanged. They exclude the preceding park as the second-registration witness. |
| R4, retirement suppresses an already-executed decrement | CLOSED | `src/patch_alloc.py:23-40` resolves a scalar token before the clone, put or upgrade primitive. `src/flock_trace.rs:220-250` accepts that token without re-querying the active address map in the outcome callback. |

For R4, a real Arc input keeps the allocation alive until the decrement. The observer token is therefore captured while the input still establishes the owner identity. If the task pauses after its nonfinal decrement and another task destroys the owner, the delayed callback still carries the same scalar token and actual fetch-sub result. It emits the matching local put event even after active-address retirement. A later unrelated allocation still receives zero from the active lookup. The correction adds no owner clone, deferred put, global logger lock, or changed production atomic result.

The destructor-completion hook captures its token before `drop_in_place` and emits after payload cleanup returns. The last decrement still reaches its observer before entering the destructor. Successful/failed Weak upgrades still report the actual CAS-loop result. No TLA+ model, enabled invariant, trace interpretation, or Linux oracle changed in this revision.

## Build-input admission

The controller supplied `evidence/private-alloc-before-v3.sha256`, whose content hash is `c4aca3c772111d32dc405c792b33fc00d314dbd266b361cc17f1726b1de2dfa8`. It records the private alloc source as the original pinned SHA-256 `2e11d0c0eb5ebabdbb3d045ed5b241869feeacff6eae9a8869bf48ebcf87eef1`. The reviewer read that evidence file and checked its hash. The controller reports that the initial attempt stopped before `patch_alloc.py`, and the separate OSDK bootstrap used the installed host standard library.

This input matters because `patch_alloc.py`'s already-installed branch recognizes a hook marker, not a hook version. An older address-ABI patch must not be reused with the new token-ABI observer. The recorded pristine input excludes that stale-hook case for this v3 admission. A future alloc-hook correction or a different/reused container must independently establish the same pristine input or the exact reviewed installed patch before building. This PASS does not authorize an unknown prepatched sysroot.

The controller should create its runtime review marker from the exact files in the hash table, including the unchanged model, Trace config, instrumentation contract and acceptance adapter. Any semantic change requires a new preserved proposal and independent review. The runner's resource checks and controller-held lock remain required.

## Evidence and remaining execution work

The updated fixture records `/proc/cmdline` before tracing begins and reports the guest's CPUID invariant-TSC bit. Source inspection confirms that the pinned kernel supports procfs and `/proc/cmdline`. The fixture mounts procfs only in the instrumented guest and closes that setup descriptor before registering the main trace task, preserving the fixture FD domain.

The collector retains this metadata, the scalar raw identity map, observed syscall results, original timestamp values and per-thread raw streams. Compression preserves timestamp order and equality. The build script records selected OSDK kernel/image artifact hashes and the fixture/initramfs hashes. The case runner records the actual per-case initramfs hash. The main runner now copies and hashes the acceptance adapter and instrumentation contract with each attempt.

Actual guest CPU count, raw clock comparability, expected case identity, complete identity/command-line metadata, zero dropped events, second-blocker identity in C08, all claimed event coverage, overlap quality, Linux return histories and complete trace consumption remain execution obligations. The current checker deliberately leaves missing event or overlap coverage incomplete. A matching preserved C06/C11 prefix does not prove syscall completion or establish a defect from elapsed time.

No definite compile/API defect was identified in this bounded corrective pass. Compilation, linking with the private alloc patch, the modified kernel boot, all guests, Linux controls and TLC are NOT_RUN by this reviewer. Failed compilation or later mismatches must retain evidence and follow the same corrective gate.

## Exact reviewed hashes

Harness paths below are relative to `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v3/inputs`. The `../spec/` entries identify unchanged companion inputs in the lane's `.specula-output/spec` directory, checked against the previously reviewed hashes.

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
| `src/patch_alloc.py` | `1a0152828b68fe1d06637e26d399ff7151e21b53706f7bebf0ec216b7885f1ce` |
| `src/run_case.sh` | `fe1c910f7ac49aa5b5d8fbbc5464f27b97aff52f9241dc53f36e3a4dcdf8942d` |
| `src/scenarios.c` | `8948cff1f7a31cbd5e1295651d0f35f8dccc2d0a85ab2ba983e4780966d68be1` |
| `../spec/base.tla` | `5114e9f43633ca283e41fec12ecd9774aef8c0f2bf89e45008834a06f71dfc08` |
| `../spec/Trace.tla` | `918b7c4afe353cf32e50bc01c598b621d7ffd667b4e8ff835d4ba78716c17abf` |
| `../spec/Trace.cfg` | `a3b384f0dd0c4155222692134581790b0f7097fbebb54c160bc24f114398a140` |
| `../spec/instrumentation-spec.md` | `beeec7c8d523d76299bee5beb9f136919465cffba680d716db95023217581f72` |
| `../spec/generation-checks/validate_trace.py` | `944aeb8ea4f6af4ca7070144a006a3451ad3d06f58992a5a922f26464b515f29` |
