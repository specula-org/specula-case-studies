# Independent review of flock harness v7

Overall verdict: **NEEDS_IMPROVEMENT** because the independently reported R5 instrumentation-boundary issue below remains open. The firmware-only v7 correction is **ACCEPTED** by source review. R1-R4 remain closed. Do not treat this artifact as a passing full-harness gate until R5 receives a reviewed correction.

Reviewer: `/root/harness_review`, independent from the harness author. Date: 2026-10-05T13:53:26.052670+00:00.

The reviewed frozen proposal is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v7`, including `inputs`, `sha256.json`, `revision.diff` and `reason.md`. Every input matches its recorded hash. Only `patches/instrumentation.patch` differs from v6, now SHA-256 `1e5c808acc8f2fafb7137de044fc89e36bf45dacd3622dca16ca9999c5863524`. The baseline remains `0c60537098f4c2949ad2d382aaf499de72263d76`.

## Firmware correction

The attempted C01 execution log is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/attempt-20261005T134356-959375469/C01.log`, SHA-256 `7e4fffe51ca0fcca2091a54adb495d532d1b94b7b578ec0f3d5d8ac262633aa9`. The recorded status is 124. The visible output ends with QEMU receiving the timeout's SIGTERM, without a fixture export. That is not evidence of flock entry, registration, a reference window, or a kernel flock deadlock.

The pinned `tools/qemu_args.sh:368-373` states that the image's rescue-image tooling provides the `x86_64-efi` platform modules and therefore enables OVMF for `grub-rescue-iso` and `grub-qcow2`. Its following firmware branch emits `-bios .../OVMF.fd`. The custom harness scheme uses `grub-rescue-iso` but previously supplied no firmware option. Adding `-bios /root/ovmf/release/OVMF.fd` restores that documented boot configuration. The controller reports that the firmware exists with SHA-256 `7d28bbc1bb6a8da1aeea3d04240b2b6da728a6445c3843b98df6c4d7e6503ccb`; this reviewer did not execute or independently read the private firmware binary.

The diff adds only that argument. It preserves SMP=2, memory=2G, KVM, serial routing, all instrumentation, tests, models and checksum gates. This is a source-supported boot correction, not proof that firmware was the timeout's sole cause or that the corrected VM will boot. The timed-out bundle and GRUB configuration remain preserved for later diagnosis.

## R5. Replacement event precedes the specified old-item Drop entry

During this review the controller separately requested examination of `TrySetLockReplace`. In the v7 patch, the event is emitted in `FlockList::try_set_lock` immediately before `list[idx] = req_lock.clone()`. The required boundary in `spec/instrumentation-spec.md:236` is after entering the old item's actual Drop, before draining its queue.

The current event can therefore publish a drain continuation while the thread is paused before the clone or old-item Drop call. Complete successful replacements are observationally equivalent for the modeled shared fields under the bounded no-OOM/no-panic fixture, but a stopped prefix is not evidence that the required Drop entry occurred. This is material to the explicit exact-trigger coverage requirement. It is not a reported production flock defect.

Disposition: **OPEN**. Save only the selected replacement index and old queue token before assignment, then emit `TrySetLockReplace` at the actual old `FlockItem::drop` entry before `wake_all`. Preserve the assignment's production ordering, the original list Mutex, queue identity, and Drop body. The pending marker must distinguish this drop from request and retain-removal drops, and it must be cleared when consumed. Preserve/review the next exact version before dependent verification.

This review used file reads and hashes only. The reviewer changed no source or harness input, ran no build, guest, control, tests, TLC or trace replay, and acquired no locks.
