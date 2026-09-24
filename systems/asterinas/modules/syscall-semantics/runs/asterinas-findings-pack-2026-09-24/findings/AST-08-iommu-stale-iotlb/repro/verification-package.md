# CR-20 — Standalone Verification Package

**Claim:** Intel VT-d IOMMU teardown in Asterinas removes page-table entries without
invalidating the IOTLB before the backing frames are returned to the frame allocator.
A device that cached the translation can therefore continue writing into kernel memory
that has already been recycled to an unrelated owner — a DMA use-after-free.

| | |
|---|---|
| **Target** | `asterinas/asterinas`, worktree HEAD `4c1fdd1e4` |
| **Architecture** | x86_64 / Intel VT-d **only** |
| **Original verdict** | `REPRODUCED` (consensus) |
| **Novelty** | **NEW** as an unreported instance, not as a class (§7.6) — re-checked 2026-08-07 against `upstream/main` `a110dfc73` |
| **Escalation level** | **0** — `ostd` logic is NOT patched |
| **Severity** | High — device writes into arbitrary recycled kernel frames, permanent |

RISC-V (`ostd/src/arch/riscv/iommu/mod.rs:22`) and LoongArch stub out `unmap`, so the
defect as written does not apply there.

> **This document is fully self-contained.** The complete reproduction harness and
> driver script are embedded in §5 and §6. Nothing outside this file is required.
> §9 lists the criteria that would **falsify** the claim — please attempt those.

---

## 1. The defect

### 1.1 Primary site — `ostd/src/mm/dma/util.rs:299-314`

```rust
fn unmap_dma_remap(daddr_range: Option<Range<Daddr>>) {
    let Some(da_range) = daddr_range else {
        return;
    };

    let _irq_gurad = irq::disable_local();

    // TODO: Free `da_range` to `allocator::daddr_allocator()`. This can only
    // be done after IOTLB flushes are supported; otherwise, reusing the freed
    // device address range may cause data corruption.

    for da in da_range.step_by(PAGE_SIZE) {
        iommu::unmap(da).unwrap();
        // FIXME: Flush IOTLBs to prevent any future DMA access to the frames.
    }
}
```

The IOMMU page-table entry is removed. No translation cache is touched.

### 1.2 The chain that frees the frames

- `unprepare_dma` — `ostd/src/mm/dma/util.rs:175-183` — calls `unmap_dma_remap`, then
  performs only TDX un-share bookkeeping. Nothing invalidates a cache.
- `DmaCoherent::drop` — `ostd/src/mm/dma/dma_coherent.rs:139-144` — calls
  `unprepare_dma`, then Rust drops `self.inner` (a `Segment<()>` or `KVirtArea`),
  returning the frames to `ostd/src/mm/frame/allocator.rs`.
- `DmaStream::drop` — `ostd/src/mm/dma/dma_stream.rs:360` — identical shape.

The release is **unconditional**; it waits on nothing.

### 1.3 No invalidation exists on this path

| Routine | Location | Reachable from teardown? |
|---|---|---|
| `IommuRegisters::global_invalidation()` | `ostd/src/arch/x86/iommu/registers/mod.rs:230-247` | No — only from interrupt-remapping setup |
| `invalidate_interrupt_cache()` | `ostd/src/arch/x86/iommu/registers/mod.rs:199-228` | No — one caller: `ostd/src/arch/x86/iommu/interrupt_remapping/mod.rs:33`, boot only |
| `iommu::unmap` | `ostd/src/arch/x86/iommu/dma_remapping/mod.rs:106-122` | Runs a page-table cursor `take_next()` only — no flush |
| `ContextTable::unmap` | `ostd/src/arch/x86/iommu/dma_remapping/context_table.rs:321-339` | Same — no flush |

**Static checks (run inside an asterinas checkout):**

```sh
# Expect: only the FIXME / TODO comments, no actual invalidation
grep -rn "IOTLB\|iotlb\|invalidate" ostd/src/mm/dma/

# Expect: 3 hits, ALL of them CPU-TLB, none on the IOMMU path — util.rs:14
# (import) and util.rs:140-141 inside `dma_remap`, which flushes the CPU TLB
# for the KVirtArea kernel mapping and *waits* on it (dispatch + sync).
# The contrast is the point: the same file flushes one cache synchronously and
# never touches the other. (An earlier revision of this document said
# "Expect: 0" here; that was wrong.)
grep -n "TlbFlusher\|issue_tlb_flush" ostd/src/mm/dma/util.rs

# Expect: exactly one commit — the one that INTRODUCED the FIXME
git log -S "Flush IOTLB" --all --oneline
```

### 1.4 Why this is a use-after-free

1. A device DMAs through `daddr`; the IOMMU caches `daddr -> paddr` in its IOTLB.
2. The `DmaCoherent`/`DmaStream` is dropped: PTE removed, **no invalidation**, frame freed.
3. The frame is handed to an unrelated kernel allocation.
4. The device issues another DMA write to the same `daddr`.
5. The stale IOTLB entry resolves it. The page walk that would have faulted against the
   now-absent PTE is **bypassed**, and the device writes into the recycled frame.

The consequence is **permanent**: nothing ever invalidates the entry, so the stale
translation survives for the life of the VM and the corruption is never detected.

---

## 2. Prerequisites on the verification host

- x86_64 Linux host
- **QEMU 11.0.2** (the original run's version) with `edu` and `intel-iommu` device
  support. Verify: `qemu-system-x86_64 -device help | grep -E 'edu|intel-iommu'`
- Rust toolchain as required by the asterinas checkout
- `nix` **optional** — the driver uses `nix develop` if present, otherwise runs the
  commands directly. Without nix you must provide the build dependencies yourself.
- An `asterinas` checkout (the "worktree" below). To reproduce the original exactly,
  check out `4c1fdd1e4`; to test current status, use `main`.
- Roughly 10–50 minutes: OSDK build up to 2400 s, ktest run up to 3000 s.

---

## 3. How to run

```sh
mkdir -p cr20 && cd cr20
# save the two files from §5 and §6 into this directory, then:
chmod +x test_bugCR-20_stale_iotlb_after_teardown.sh
./test_bugCR-20_stale_iotlb_after_teardown.sh /path/to/asterinas
```

The driver will:
1. Copy the harness to `<worktree>/ostd/src/cr20_repro.rs` and register the module in
   `ostd/src/lib.rs` (idempotent).
2. Back up `<worktree>/ostd/OSDK.toml`, install QEMU args with IOMMU + `edu` + vIOMMU
   tracing, and **restore the original on exit via a trap**.
3. Build a source-local OSDK from that same worktree.
4. Run the single ktest and print a guest-output and host-event summary.

Environment overrides: `OSDK_BIN`, `BUILD_TIMEOUT_SECONDS` (2400), `TEST_TIMEOUT_SECONDS`
(3000), `SMP` (2).

> **Why the OSDK must be built from the worktree under test:** OSDK bakes
> `CARGO_MANIFEST_DIR` in at its own compile time and derives the `ostd` path dependency
> from it. An OSDK binary built from another checkout would silently test *that*
> checkout's `ostd`. Only set `OSDK_BIN` if you understand this.

> **`-m 8G` is mandatory.** The IOMMU registers sit near `0xfed90000` and `ostd` reaches
> them through the linear map, which only covers `0..max_paddr`. With ostd's default 2G
> the kernel faults inside `iommu::init`. This is a harness constraint, not part of the
> defect.

---

## 4. Expected result — **READ THIS BEFORE INTERPRETING THE OUTPUT**

> ### The ktest **FAILS** when the bug reproduces. A failing test is the positive result.
>
> The harness ends with:
> ```rust
> assert_ne!(after_replay, pattern_device,
>     "CR-20: a device wrote into a frame that the kernel had already unmapped ...");
> ```
> If the device clobbered the recycled frame, `after_replay == pattern_device`, the
> assertion fires, and the ktest reports `FAILED` with a non-zero exit status.
> **`test result: FAILED. 0 passed; 1 failed` == the bug reproduced.**
> A *passing* test would mean the bug is absent (i.e. fixed, or not present on your host).

### 4.1 Guest output from the original run

```
CR20| ================ finding CR-20 ================
CR20| claim: unmap_dma_remap() removes the IOMMU PTE and frees the frame without
      invalidating any translation cache
CR20| DMA remapping is enabled
CR20| edu device at bus 0 dev 3 fn 0, BAR0=0xfea00000, command=0x100107
CR20| phase 1: mapped DmaCoherent daddr=0x3fffffe000 -> paddr=0x13206000
CR20| phase 1: device round-trip through the IOMMU: wrote d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1
      read d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1
CR20| phase 2: dropped the DmaCoherent (unprepare_dma -> iommu::unmap, no IOTLB flush),
      frame 0x13206000 is back in the allocator
CR20| phase 2: frame 0x13206000 is now an ordinary kernel allocation holding
      5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a
CR20| control: device wrote to never-mapped daddr=0x403fffe000 (completed=true),
      witness frame now 5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a
CR20| phase 3: device wrote to the revoked daddr=0x3fffffe000 (completed=true),
      witness frame now d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1
CR20| SUMMARY daddr=0x3fffffe000 paddr=0x13206000
      witness_intact_after_control=true witness_clobbered_after_replay=true
CR20| REPRODUCED: after unprepare_dma() removed the PTE and the frame was recycled,
      the device still wrote 64 bytes into it
test result: FAILED. 0 passed; 1 failed; 202 filtered out.
```

### 4.2 Host-side vIOMMU event counts from the original run

```
IOTLB fills   : 1
IOTLB hits    : 2
IOTLB flushes : 0      <-- the guest NEVER invalidates anything, over the whole boot+run
DMAR faults   : 16     <-- all from the control write to the never-mapped address
```

The decisive trace line, emitted twice:

```
vtd_iotlb_page_hit IOTLB page hit sid 0x18 iova 0x3fffffe000 slpte 0x13206083 domain 0x0
```

`sid 0x18` is the `edu` device, `iova 0x3fffffe000` is the revoked device address, and
`slpte 0x13206083` points at physical frame `0x13206000` — the frame already handed back
to the allocator.

### 4.3 Why the control is the load-bearing part

The control writes to a device address **1 GiB above** the live mapping, which
`daddr_allocator` never handed out, so no PTE and no cache entry can exist for it. It was
rejected with **16 DMAR faults** and the witness frame stayed `5a5a…`.

This proves the IOMMU is genuinely enforcing in this configuration. Without it, a
successful phase-3 write could simply mean translation was off. The only thing that let
the revoked access through was the un-invalidated cache.

**Both conditions must hold for a valid positive result:**
`witness_intact_after_control=true` **and** `witness_clobbered_after_replay=true`.

---

## 5. Reproduction harness — `test_bugCR-20_stale_iotlb_after_teardown.rs`

Save verbatim next to the driver script.

```rust
// SPDX-License-Identifier: MPL-2.0

//! Reproduction harness for finding CR-20, "IOMMU teardown removes PTEs
//! without device-IOTLB invalidation before frame reuse".
//!
//! The claim under test: `unmap_dma_remap()` (`ostd/src/mm/dma/util.rs:299`)
//! removes the device page-table entries for a DMA object and then lets the
//! backing frames go straight back to the frame allocator, without ever
//! invalidating the translation caches that sit in front of that page table.
//! A device (or the IOMMU itself) that cached the translation therefore keeps
//! a usable path into a frame the kernel has already handed to somebody else.
//!
//! The harness drives a real PCI device (QEMU's `edu` device, which does
//! honest `pci_dma_read`/`pci_dma_write` through its IOMMU address space) and
//! measures whether the kernel's teardown actually revokes the device's
//! access:
//!
//!   phase 1  map a `DmaCoherent`, let the device read and write it through
//!            the IOMMU. This is ordinary driver usage and it warms the
//!            translation cache for that device address.
//!   phase 2  drop the `DmaCoherent`. `unprepare_dma()` removes the PTE; the
//!            frame is freed. Take the very same frame back out of the frame
//!            allocator as an ordinary, non-DMA kernel allocation and stamp a
//!            witness pattern into it.
//!   phase 3  tell the device to write to the same device address again.
//!            After a correct teardown the IOMMU must reject this: the PTE is
//!            gone. If a stale cached translation survives, the write lands in
//!            the recycled frame and destroys the witness pattern.
//!
//! Control: the same device write aimed at a device address that was *never*
//! mapped. It isolates "the stale cache entry let it through" from "the IOMMU
//! is not enforcing anything here".
//!
//! Escalation level 0/1: no ostd logic is modified. Everything runs through
//! the public DMA API plus ordinary PCI config / MMIO device programming.

use alloc::{vec, vec::Vec};

use crate::{
    arch::{
        device::io_port::{ReadWriteAccess, WriteOnlyAccess},
        iommu::has_dma_remapping,
        read_tsc, tsc_freq,
    },
    io::{IoMem, IoPort},
    mm::{
        Daddr, FrameAllocOptions, HasDaddr, HasPaddr, PAGE_SIZE, Paddr, VmIo, VmIoOnce,
        dma::DmaCoherent,
    },
    prelude::*,
};

// ---------------------------------------------------------------- PCI config

const PCI_CFG_ADDR_PORT: u16 = 0xCF8;
const PCI_CFG_DATA_PORT: u16 = 0xCFC;

const PCI_REG_ID: u8 = 0x00;
const PCI_REG_COMMAND: u8 = 0x04;
const PCI_REG_BAR0: u8 = 0x10;

/// Memory Space Enable | Bus Master Enable.
const PCI_CMD_MEM_AND_MASTER: u32 = 0b110;

struct PciCfg {
    addr: IoPort<u32, WriteOnlyAccess>,
    data: IoPort<u32, ReadWriteAccess>,
}

impl PciCfg {
    fn new() -> Option<Self> {
        // 0xCF9 is the PIIX4 reset control register, so 0xCF8 has to be
        // acquired as an overlapping port -- same as `aster-pci` does.
        let addr = IoPort::acquire_overlapping(PCI_CFG_ADDR_PORT).ok()?;
        let data = IoPort::acquire(PCI_CFG_DATA_PORT).ok()?;
        Some(Self { addr, data })
    }

    fn encode(bdf: (u8, u8, u8), offset: u8) -> u32 {
        (1 << 31)
            | ((bdf.0 as u32) << 16)
            | (((bdf.1 as u32) & 0b1_1111) << 11)
            | (((bdf.2 as u32) & 0b111) << 8)
            | ((offset as u32) & 0xfc)
    }

    fn read32(&self, bdf: (u8, u8, u8), offset: u8) -> u32 {
        self.addr.write(Self::encode(bdf, offset));
        self.data.read()
    }

    fn write32(&self, bdf: (u8, u8, u8), offset: u8, value: u32) {
        self.addr.write(Self::encode(bdf, offset));
        self.data.write(value);
    }
}

// ------------------------------------------------------------- the edu device

/// QEMU's educational PCI device: vendor 0x1234, device 0x11e8.
const EDU_ID: u32 = 0x11e8_1234;

const EDU_REG_DMA_SRC: usize = 0x80;
const EDU_REG_DMA_DST: usize = 0x88;
const EDU_REG_DMA_CNT: usize = 0x90;
const EDU_REG_DMA_CMD: usize = 0x98;

/// Addresses in `[EDU_BUF_BASE, EDU_BUF_BASE + 4096)` name the device's own
/// internal buffer; anything else is a bus address the device DMAs to/from.
const EDU_BUF_BASE: u64 = 0x4_0000;

const EDU_DMA_RUN: u64 = 1;
/// Direction bit: clear = bus -> device, set = device -> bus.
const EDU_DMA_TO_BUS: u64 = 2;
const EDU_DMA_FROM_BUS: u64 = 0;

/// How many bytes each DMA moves.
const XFER: usize = 64;

struct Edu {
    bdf: (u8, u8, u8),
    mmio: IoMem,
}

impl Edu {
    fn find(cfg: &PciCfg) -> Option<Self> {
        let mut found = None;
        'scan: for device in 0..32u8 {
            for function in 0..8u8 {
                let bdf = (0u8, device, function);
                if cfg.read32(bdf, PCI_REG_ID) == EDU_ID {
                    found = Some(bdf);
                    break 'scan;
                }
            }
        }
        let bdf = found?;

        let command = cfg.read32(bdf, PCI_REG_COMMAND);
        cfg.write32(bdf, PCI_REG_COMMAND, command | PCI_CMD_MEM_AND_MASTER);

        let bar0 = (cfg.read32(bdf, PCI_REG_BAR0) & 0xffff_fff0) as usize;
        if bar0 == 0 {
            println!("CR20| edu found at {:?} but BAR0 is unassigned", bdf);
            return None;
        }
        let mmio = match IoMem::acquire(bar0..bar0 + PAGE_SIZE) {
            Ok(mmio) => mmio,
            Err(err) => {
                println!("CR20| cannot acquire edu BAR0 {:#x}: {:?}", bar0, err);
                return None;
            }
        };

        println!(
            "CR20| edu device at bus {} dev {} fn {}, BAR0={:#x}, command={:#x}",
            bdf.0,
            bdf.1,
            bdf.2,
            bar0,
            cfg.read32(bdf, PCI_REG_COMMAND),
        );
        Some(Self { bdf, mmio })
    }

    /// Runs one DMA and waits for the device to report completion.
    ///
    /// Returns `false` if the device never cleared the RUN bit.
    fn dma(&self, src: u64, dst: u64, cnt: u64, dir: u64) -> bool {
        self.mmio.write_once(EDU_REG_DMA_SRC, &src).unwrap();
        self.mmio.write_once(EDU_REG_DMA_DST, &dst).unwrap();
        self.mmio.write_once(EDU_REG_DMA_CNT, &cnt).unwrap();
        self.mmio
            .write_once(EDU_REG_DMA_CMD, &(dir | EDU_DMA_RUN))
            .unwrap();

        // The device runs the transfer off a 100 ms virtual timer.
        let start = read_tsc();
        let budget = tsc_freq().saturating_mul(20).max(1);
        loop {
            let cmd: u64 = self.mmio.read_once(EDU_REG_DMA_CMD).unwrap();
            if cmd & EDU_DMA_RUN == 0 {
                return true;
            }
            if read_tsc().wrapping_sub(start) > budget {
                println!("CR20| edu DMA did not complete within 20 s (cmd={:#x})", cmd);
                return false;
            }
            core::hint::spin_loop();
        }
    }
}

// ------------------------------------------------------------------ the test

fn hex(bytes: &[u8]) -> alloc::string::String {
    use core::fmt::Write;
    let mut out = alloc::string::String::new();
    for byte in bytes.iter().take(16) {
        let _ = write!(out, "{:02x}", byte);
    }
    out
}

/// Pulls frames out of the allocator until the one at `paddr` comes back.
///
/// Returns `None` if it never does within the budget; every other frame taken
/// on the way is released again.
fn reclaim_frame(paddr: Paddr) -> Option<crate::mm::Frame<()>> {
    let mut detour = Vec::new();
    let mut hit = None;
    for _ in 0..4096 {
        let frame = FrameAllocOptions::new().zeroed(false).alloc_frame().unwrap();
        if frame.paddr() == paddr {
            hit = Some(frame);
            break;
        }
        detour.push(frame);
    }
    drop(detour);
    hit
}

#[ktest]
fn cr20_stale_iotlb_after_dma_teardown() {
    println!("CR20| ================ finding CR-20 ================");
    println!(
        "CR20| claim: unmap_dma_remap() removes the IOMMU PTE and frees the frame \
         without invalidating any translation cache"
    );

    if !has_dma_remapping() {
        println!(
            "CR20| ENV: DMA remapping is not enabled in this VM; the cited path \
             (dma_remap/unmap_dma_remap) is dead here. Boot with -device intel-iommu."
        );
        return;
    }
    println!("CR20| DMA remapping is enabled");

    let Some(cfg) = PciCfg::new() else {
        println!("CR20| ENV: cannot acquire the PCI configuration ports");
        return;
    };
    let Some(edu) = Edu::find(&cfg) else {
        println!("CR20| ENV: no QEMU edu device on the bus; add -device edu");
        return;
    };

    let pattern_device = vec![0xD1u8; XFER];
    let pattern_witness = vec![0x5Au8; XFER];

    // ---- phase 1: ordinary driver usage of a live DMA mapping --------------

    let dma = DmaCoherent::alloc(1, true).unwrap();
    let daddr: Daddr = dma.daddr();
    let paddr: Paddr = dma.paddr();
    println!(
        "CR20| phase 1: mapped DmaCoherent daddr={:#x} -> paddr={:#x}",
        daddr, paddr
    );

    dma.write_bytes(0, &pattern_device).unwrap();
    // The device reads the buffer over the bus. This is a real translated
    // read of `daddr`.
    if !edu.dma(daddr as u64, EDU_BUF_BASE, XFER as u64, EDU_DMA_FROM_BUS) {
        println!("CR20| ENV: the device never completed the first DMA");
        return;
    }

    // Wipe the buffer and have the device write it back, so we know the device
    // can both read and write through the live mapping.
    dma.write_bytes(0, &vec![0u8; XFER]).unwrap();
    if !edu.dma(EDU_BUF_BASE, daddr as u64, XFER as u64, EDU_DMA_TO_BUS) {
        println!("CR20| ENV: the device never completed the second DMA");
        return;
    }
    let mut readback = vec![0u8; XFER];
    dma.read_bytes(0, &mut readback).unwrap();
    println!(
        "CR20| phase 1: device round-trip through the IOMMU: wrote {} read {}",
        hex(&pattern_device),
        hex(&readback)
    );
    assert_eq!(
        readback, pattern_device,
        "the device could not DMA through the live mapping; the harness is not \
         exercising the IOMMU at all"
    );

    // ---- phase 2: teardown, then hand the frame to a non-DMA owner ---------

    drop(dma);
    println!(
        "CR20| phase 2: dropped the DmaCoherent (unprepare_dma -> iommu::unmap, \
         no IOTLB flush), frame {:#x} is back in the allocator",
        paddr
    );

    let Some(victim) = reclaim_frame(paddr) else {
        println!(
            "CR20| ENV: frame {:#x} did not come back from the allocator",
            paddr
        );
        return;
    };
    victim.write_bytes(0, &pattern_witness).unwrap();
    let mut check = vec![0u8; XFER];
    victim.read_bytes(0, &mut check).unwrap();
    println!(
        "CR20| phase 2: frame {:#x} is now an ordinary kernel allocation holding {}",
        victim.paddr(),
        hex(&check)
    );
    assert_eq!(check, pattern_witness);

    // ---- control: a device address that was never mapped -------------------

    // 1 GiB above the live mapping: never allocated by `daddr_allocator`, so no
    // PTE and no cache entry can exist for it.
    let never_mapped = daddr as u64 + 0x4000_0000;
    let control_ok = edu.dma(EDU_BUF_BASE, never_mapped, XFER as u64, EDU_DMA_TO_BUS);
    let mut after_control = vec![0u8; XFER];
    victim.read_bytes(0, &mut after_control).unwrap();
    println!(
        "CR20| control: device wrote to never-mapped daddr={:#x} (completed={}), \
         witness frame now {}",
        never_mapped,
        control_ok,
        hex(&after_control)
    );

    // ---- phase 3: the device reuses the address the kernel revoked ---------

    let replay_ok = edu.dma(EDU_BUF_BASE, daddr as u64, XFER as u64, EDU_DMA_TO_BUS);
    let mut after_replay = vec![0u8; XFER];
    victim.read_bytes(0, &mut after_replay).unwrap();
    println!(
        "CR20| phase 3: device wrote to the revoked daddr={:#x} (completed={}), \
         witness frame now {}",
        daddr, replay_ok, hex(&after_replay)
    );

    let clobbered = after_replay == pattern_device;
    println!(
        "CR20| SUMMARY daddr={:#x} paddr={:#x} witness_intact_after_control={} \
         witness_clobbered_after_replay={}",
        daddr,
        paddr,
        after_control == pattern_witness,
        clobbered
    );
    if clobbered {
        println!(
            "CR20| REPRODUCED: after unprepare_dma() removed the PTE and the frame \
             was recycled, the device still wrote {} bytes into it",
            XFER
        );
    } else {
        println!(
            "CR20| NOT REPRODUCED at this level: the post-teardown device write did \
             not reach the recycled frame"
        );
    }

    assert_eq!(
        after_control, pattern_witness,
        "control failed: the IOMMU let a never-mapped device address through, so \
         the harness cannot attribute anything to a stale cache entry"
    );
    assert_ne!(
        after_replay, pattern_device,
        "CR-20: a device wrote into a frame that the kernel had already unmapped \
         from the IOMMU and returned to the frame allocator"
    );
}
```

---

## 6. Driver script — `test_bugCR-20_stale_iotlb_after_teardown.sh`

Save verbatim next to the harness, then `chmod +x`.

```bash
#!/usr/bin/env bash
# Reproduction driver for finding CR-20:
#   "IOMMU teardown removes PTEs without device-IOTLB invalidation before
#    frame reuse"
#
# What it does
#   1. Installs the ktest into the Asterinas worktree (idempotent).
#   2. Swaps `ostd/OSDK.toml`'s test QEMU arguments for ones that (a) turn on
#      the Intel IOMMU with the same options the product's own `iommu` scheme
#      uses (`tools/qemu_args.sh iommu`), (b) attach QEMU's `edu` PCI device so
#      the guest has a real device that performs real bus DMA, and (c) turn on
#      the vIOMMU translation-cache trace events so the host can see whether
#      the guest ever invalidates anything. The original file is restored on
#      exit, always.
#   3. Boots ostd's ktest kernel under QEMU and runs the single CR-20 ktest
#      against UNMODIFIED ostd sources.
#
# Escalation level: 0/1. No ostd logic is patched; the guest only uses the
# public DMA API plus ordinary PCI config-space / MMIO device programming.
#
# Usage: test_bugCR-20_stale_iotlb_after_teardown.sh [worktree]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="${1:-$HERE/../confirmation/CR-20/worktree}"
WORKTREE="$(cd "$WORKTREE" && pwd)"
# The OSDK bakes `CARGO_MANIFEST_DIR` in at its own compile time and derives
# the `ostd` path dependency from it, so a binary built from another checkout
# would silently test *that* checkout's ostd. Build it from this worktree.
OSDK_BIN="${OSDK_BIN:-$WORKTREE/osdk/target/debug/cargo-osdk}"
LOG="$HERE/test_bugCR-20_stale_iotlb_after_teardown.log"
BUILD_TIMEOUT_SECONDS="${BUILD_TIMEOUT_SECONDS:-2400}"
TEST_TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-3000}"
FILTER=cr20_repro::cr20_stale_iotlb_after_dma_teardown
SMP="${SMP:-2}"

OSDK_TOML="$WORKTREE/ostd/OSDK.toml"
OSDK_TOML_BACKUP="$OSDK_TOML.cr20-orig"

in_dev_shell() {
    local directory="$1" limit="$2"
    shift 2
    if command -v nix >/dev/null 2>&1; then
        (cd "$directory" && timeout "$limit" nix develop "$WORKTREE" \
            --accept-flake-config --command "$@")
    else
        (cd "$directory" && timeout "$limit" "$@")
    fi
}

install_sources() {
    cp "$HERE/test_bugCR-20_stale_iotlb_after_teardown.rs" \
        "$WORKTREE/ostd/src/cr20_repro.rs"
    if ! grep -q "mod cr20_repro;" "$WORKTREE/ostd/src/lib.rs"; then
        python3 - "$WORKTREE/ostd/src/lib.rs" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
anchor = "#[cfg(ktest)]\nmod tla_scenarios;\n"
addition = "#[cfg(ktest)]\npub(crate) mod cr20_repro;\n"
if anchor in text:
    text = text.replace(anchor, anchor + addition, 1)
else:
    text = text.rstrip("\n") + "\n\n" + addition
path.write_text(text)
print("registered mod cr20_repro in", path)
PY
    fi
}

restore_qemu_args() {
    if [[ -f "$OSDK_TOML_BACKUP" ]]; then
        mv "$OSDK_TOML_BACKUP" "$OSDK_TOML"
        echo "restored $OSDK_TOML"
    fi
}

install_qemu_args() {
    cp "$OSDK_TOML" "$OSDK_TOML_BACKUP"
    cat >"$OSDK_TOML" <<'TOML'
[boot]
method = "qemu-direct"

# 8G of RAM, matching the product's own `iommu` scheme: the IOMMU registers sit
# at ~0xfed90000 and ostd reaches them through the linear map, which only covers
# 0..max_paddr. With ostd's default 2G the kernel faults inside `iommu::init`.
[test.qemu]
args = """
    -machine q35,kernel-irqchip=split
    -cpu max,+x2apic
    -smp ${SMP:-2}
    -m 8G
    --no-reboot
    -nographic
    -display none
    -serial stdio
    -monitor none
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
    -device intel-iommu,intremap=on,device-iotlb=on
    -device edu,dma_mask=0xffffffffff
    -trace enable=vtd_iotlb_page_hit
    -trace enable=vtd_iotlb_page_update
    -trace enable=vtd_iotlb_reset
    -trace enable=vtd_inv_desc_iotlb_global
    -trace enable=vtd_inv_desc_iotlb_domain
    -trace enable=vtd_inv_desc_iotlb_pages
    -trace enable=vtd_dmar_fault
"""
TOML
    echo "installed the CR-20 QEMU arguments (IOMMU + edu device + vtd tracing)"
}

build_osdk() {
    if [[ -x "$OSDK_BIN" ]]; then
        echo "== OSDK already built: $OSDK_BIN"
        return
    fi
    echo "== building the source-local OSDK"
    in_dev_shell "$WORKTREE" "$BUILD_TIMEOUT_SECONDS" \
        env OSDK_LOCAL_DEV=1 cargo build --manifest-path osdk/Cargo.toml
}

run_ktest() {
    echo "== running $FILTER with SMP=$SMP"
    set +e
    in_dev_shell "$WORKTREE/ostd" "$TEST_TIMEOUT_SECONDS" \
        env SMP="$SMP" "$OSDK_BIN" osdk test "$FILTER" --target-arch x86_64 \
        >"$LOG" 2>&1
    local status=$?
    set -e
    echo "-- exit status: $status"
    return $status
}

install_sources
build_osdk

trap restore_qemu_args EXIT
install_qemu_args

status=0
run_ktest || status=$?

restore_qemu_args
trap - EXIT

echo
echo "######## guest output ########"
grep -E "^CR20\||test result|panicked at|iommu:" "$LOG" || true
echo
echo "######## host-side vIOMMU translation-cache events ########"
echo "IOTLB fills   : $(grep -c 'vtd_iotlb_page_update' "$LOG" || true)"
echo "IOTLB hits    : $(grep -c 'vtd_iotlb_page_hit' "$LOG" || true)"
echo "IOTLB flushes : $(grep -cE 'vtd_inv_desc_iotlb_|vtd_iotlb_reset' "$LOG" || true)"
echo "DMAR faults   : $(grep -c 'vtd_dmar_fault' "$LOG" || true)"
echo
echo "RESULT: ktest exit status $status (full log: $LOG)"
exit "$status"
```

> The default `WORKTREE` in the script points at the original Specula layout. Always
> pass your own checkout path as the first argument.

---

## 7. Novelty check — re-run this, it is time-sensitive

**Last re-checked 2026-08-07** against `upstream/main` = `a110dfc73` ("Update page cache
tests", 2026-08-06), verified as the live remote tip via
`git ls-remote https://github.com/asterinas/asterinas refs/heads/main`.

### 7.1 Code state — still unfixed

`unmap_dma_remap` on `upstream/main` is byte-for-byte the §1.1 listing: same TODO, same
FIXME, no invalidation. `git log -S "Flush IOTLB" --all --oneline` still returns exactly
one commit, `71681dd94`, the one that introduced the FIXME. Nothing in
`ostd/src/arch/x86/iommu/` has changed on the invalidation side; the descriptor module
still defines only `InterruptEntryCache` (type 4) and `InvalidationWait` (type 5).

### 7.2 Searches run — nothing filed

| Source | Query | Result |
|---|---|---|
| GitHub issues + PRs (`asterinas/asterinas`) | `IOTLB`, `iommu invalidation`, `iommu unmap`, `unmap_dma_remap`, `stale DMA mapping`, `device TLB`, `DMA use-after-free`, `flush IOTLB`, `translation cache`, `DMA teardown`, `use-after-free`, `dma_unmap`, `DmaCoherent drop` | no report of this defect |
| GitHub issues + PRs, `created:>=2026-07-20` | `iommu`, `dma` | 4 items, none related |
| GitHub commit search | `iotlb` | 0 |
| GitHub security advisories (repo) | — | 0 |
| GitHub global advisory DB | `affects=asterinas` | 0 |
| NVD | `keywordSearch=asterinas` | `totalResults: 0` |
| OSV | crates `ostd`, `asterinas` | `{}` |
| RustSec `advisory-db` | `asterinas`, `ostd` | 0 |

**No issue, PR, CVE or advisory reports this defect.** The only in-tree record is the
FIXME comment, which is not a filed report.

### 7.3 Nearest hits

All different mechanisms: #3313 (virtio-net perf, host vhost bug), #3354 / #3474 (RISC-V
IOMMU), #3108 / #2351 (the PRs that *carry* the FIXME), #1460 (deadlock in iommu
remapping), #3672 / #3673 (RISC-V **CPU** TLB after page-table activation), #2939 (CoCo
tracking), #3102 (`PADDR_REF_CNTS` deadlock in DMA alloc/free), #3605 (virtio-fs DMA
arena — reuses buffers rather than re-mapping, so it *sidesteps* teardown; not a fix).

**#2849 — the closest existing report, and it is not this one.** "KVirtArea Drop doesn't
flush remote TLBs, use-after-free risk in vmalloc ranges" (open, `C-bug`, filed
2026-01-05 by an external unsafe-code auditor; marked `S-stale` 2026-08-03 and slated for
auto-close). Same *shape* — unmap, recycle, never invalidate the stale cache — but a
different cache (CPU TLB) in a different subsystem (`kspace/kvirt_area.rs`).

Two reasons it belongs here. First, any verifier searching `use-after-free` lands on it,
so it must be explicitly distinguished. Second, the maintainer reply (junyang-zh,
2026-01-06) sets the expectation for how this class is triaged: TLB coherence is "ensured
by the caller", flushing on every drop would hurt task-drop performance because the kernel
stack is a `KVirtArea`, "I don't like it either", keep the issue open until a proper fix.
Acknowledged, deprioritized on performance grounds — not disputed.

The DMA path actually *satisfies* #2849's caller-ensures contract: `dma_remap` issues and
waits on a CPU-TLB flush for its `KVirtArea` (`util.rs:139-143`). Same file, same
function pair, one cache flushed synchronously and the other never touched.

### 7.4 Class prior art — the mechanism is documented, this instance is not

The exploit primitive is established literature, not a new discovery:

- ["IOMMU Deferred Invalidation Vulnerability: Exploit and Defense"](https://bu-icsg.github.io/publications/2024/iommu_date_2024.pdf) (DATE 2024) — Linux defers
  IOTLB invalidation for throughput, leaving a window in which a peripheral reaches
  unmapped-then-reallocated memory through a stale entry.
- [Thunderclap](https://www.ndss-symposium.org/ndss-paper/thunderclap-exploring-vulnerabilities-in-operating-system-iommu-protection-via-dma-from-untrustworthy-peripherals/) (NDSS 2019) — OS IOMMU protection defeated by DMA from untrusted
  peripherals, including via mapping-lifetime gaps.

The difference is degree, and it runs the wrong way for Asterinas: Linux **defers**
invalidation, so the window is bounded and closes. Asterinas **omits** it, so the stale
translation is permanent (§1.4). Do not present this to maintainers as a novel class of
bug — present it as a known class, in its worst form, unfixed.

### 7.5 History

The FIXME was introduced by `71681dd94` "Refactor DMA APIs" (2025-12-04, PR #2351) and
carried forward unchanged by `c589350ca` "Clarify whether DMA operations can be used in
IRQs" (2026-04-09, PR #3108). **No commit has ever attempted a fix.**

The developers were aware of *half* the problem. The TODO at `util.rs:306-308` says
freeing device addresses "can only be done after IOTLB flushes are supported; otherwise,
reusing the freed device address range may cause data corruption" — which is why the
daddr allocator leaks by design. That covers **device-address** reuse. It says nothing
about **frame** reuse, which is the actual use-after-free.

### 7.6 Verdict

**NEW as an unreported instance, not as a new class** — nothing filed anywhere reports
this defect against Asterinas (§7.2), but omitting IOTLB invalidation before frame reuse
is published prior art (§7.4), and Asterinas's variant is the unbounded one.



---

## 8. Suggested verification order

1. **Static (minutes).** Confirm §1.1–1.3 against the checkout under test. Does
   `unmap_dma_remap` still lack any invalidation? Is `invalidate_interrupt_cache()` still
   boot-only? Run the three commands in §1.3.
2. **Novelty (minutes).** Re-run the §7 searches. This is the item most likely to have
   changed since 2026-08-06.
3. **Dynamic (up to ~1 h).** Run §3 and check the §4 markers — remembering that a
   **FAILED** ktest is the positive result.
4. **Independent harness (best evidence).** Write your own reproduction rather than only
   re-running this one. An independent harness that fails to reproduce under the same
   configuration would be the strongest disconfirmation.

---

## 9. Falsification criteria — the claim is WRONG if any of these hold

- An invalidation **is** issued on the teardown path — statically, or a nonzero
  `IOTLB flushes` count in the §4.2 summary.
- `witness_intact_after_control=false` — the IOMMU let a never-mapped address through,
  so the harness cannot attribute anything to a stale cache entry and proves nothing.
- The frame is not actually recycled into an unrelated allocation in phase 2 (watch for
  the `ENV: frame ... did not come back from the allocator` message) — then the
  "use-after-free" framing is wrong even if the cache is stale.
- `witness_clobbered_after_replay=false` — the post-teardown device write did not reach
  the recycled frame; no stale translation was used.
- The observed write is explained by something other than the IOTLB, e.g. the `edu`
  device bypassing translation entirely. The `vtd_iotlb_page_hit ... slpte 0x13206083`
  trace argues against this, but confirm it independently.

---

## 10. Known limitations — please weigh these

- **Single environment.** One reproduction environment (QEMU 11.0.2 + vIOMMU + `edu`).
  **Not validated on physical VT-d hardware.** On bare metal there is no `edu` device, so
  a hardware verification needs a different DMA master — ideally one with ATS enabled,
  driven through the same `DmaCoherent`/`DmaStream` teardown path. Treat bare-metal
  behaviour as unverified until someone does this.
- **Synthetic device.** `edu` is a test device. A production driver's teardown ordering
  may differ. However, the defect lives in `ostd`'s generic DMA path, not in any driver,
  so every DMA consumer traverses it.
- **QEMU is not hardware.** A vIOMMU's caching behaviour is a model of VT-d, not VT-d.
  Real hardware may cache more or less aggressively; that changes exploitability and
  timing, not the absence of the invalidation call.
- **`-m 8G`** is a harness constraint (linear-map coverage of the IOMMU MMIO), unrelated
  to the defect.
- **Device-IOTLB vs IOMMU IOTLB.** The observed stale entry is in the vIOMMU's own IOTLB
  (`vtd_iotlb_page_hit`). The run used `device-iotlb=on`, and the tree has **no ATS
  support at all** (`grep -rn "ats\|ATS\|device_tlb" ostd/src/arch/x86/iommu/` returns
  nothing), so a complete fix must address device-side caches too.
- **Residue.** The driver leaves `ostd/src/cr20_repro.rs` and its `mod` registration in
  the worktree. It restores `ostd/OSDK.toml` automatically.

---

## 11. Fix direction (context, not part of verification)

Infrastructure that already exists: queued invalidation is enabled at boot
(`ostd/src/arch/x86/iommu/invalidate/mod.rs:12-30`), `invalidate_interrupt_cache()`
(`registers/mod.rs:199-228`) is a working submit-and-wait template, and the
`iotlb_invalidate` register is mapped.

Missing: `ostd/src/arch/x86/iommu/invalidate/descriptor/mod.rs` defines only
`InterruptEntryCache` (type 4) and `InvalidationWait` (type 5). There is **no IOTLB
Invalidate descriptor**, **no Device-TLB Invalidate descriptor**, and **no ATS support**.

1. Add an IOTLB Invalidate descriptor; submit it **batched per `da_range`** (not per
   page) followed by an `InvalidationWait`, and gate the frame release on completion —
   mirroring `TlbFlusher::issue_tlb_flush_with`'s retained-owner contract.
2. Add Device-TLB invalidation for ATS-capable devices; required for completeness given
   `device-iotlb=on`.
3. Minimal stopgap: reuse the register-based global IOTLB invalidation and add a wait
   loop (today's `global_invalidation()` writes the register but does not wait). Coarse,
   costly, and does not cover device-IOTLB.
4. Once teardown is safe, the `util.rs:306` TODO can be resolved and `da_range` returned
   to `daddr_allocator()`, which leaks by design today.

Two implementation traps: `unmap_dma_remap` runs under `irq::disable_local()`, so
spinning on hardware completion there lengthens the IRQ-disabled window; and
`Queue::append_descriptor` (`ostd/src/arch/x86/iommu/invalidate/queue.rs:17-24`) has **no
queue-full / wraparound protection** — it resets `tail` at `queue_size` and never checks
the head. That was safe when the queue was used once at boot, but not if every DMA
teardown enqueues.
