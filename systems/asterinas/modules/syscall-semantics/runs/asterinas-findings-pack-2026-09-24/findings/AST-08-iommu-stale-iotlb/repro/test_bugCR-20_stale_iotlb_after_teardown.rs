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
