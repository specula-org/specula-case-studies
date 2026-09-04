// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// Configuration
//==================================================================================================

#![no_std]
#![no_main]

//==================================================================================================
// Imports
//==================================================================================================

extern crate libc_string;
extern crate nvx;
extern crate nvx_crt0;

use ::sys::{
    error::{
        Error,
        ErrorCode,
    },
    kcall::{
        mm,
        pm,
    },
    mm::Address,
    pm::Capability,
};

//==================================================================================================
// Constants
//==================================================================================================

/// Encoded 8-byte "RAMFS   " tag exposed by the MicroVM RAMFS MMIO region.
const RAMFS_MMIO_TAG: u64 = u64::from_be_bytes(*b"RAMFS   ");

//==================================================================================================
// Entry Point
//==================================================================================================

///
/// # Description
///
/// Reproduction for finding CR-10 (mmio_free drops the ownership record without revoking the
/// underlying page-table entries).
///
/// The test drives ONLY the public kernel-call interface:
///   1. capctl(IoManagement)          -- acquire the I/O management capability.
///   2. mmio_alloc(RAMFS)             -- map the region (pages become user-accessible).
///   3. mmio_info(RAMFS)             -- learn the region's base address.
///   4. read a byte at base           -- baseline: succeeds because the region is mapped.
///   5. mmio_free(RAMFS)             -- "detach" the region.
///   6. read a byte at base AGAIN.
///
/// # Expected (correct) behavior
///
/// `mmio_free` detaches the region, so a correct implementation revokes the page-table entries.
/// The post-free read at step 6 then hits an unmapped page -> page fault -> the kernel maps it to
/// `SIGSEGV`; with no handler installed the default action terminates the process with exit code 4
/// (`EINTR`), exactly like `test-rust-mmio-fault`. The runner is configured to expect exit code 4.
///
/// # Buggy behavior (the finding)
///
/// `mmio_free` only removes the bookkeeping entry and never revokes the PTEs, so the post-free read
/// SUCCEEDS (no fault). Control falls through past step 6, we log a `BUGCR10` marker, and `main`
/// returns `Ok(())` -> exit code 0. An observed exit code of 0 (instead of 4) demonstrates the
/// stale-mapping / use-after-free consequence.
///
#[no_mangle]
pub fn main() -> Result<(), Error> {
    // Acquire IO management capability.
    pm::__kcall_capctl(Capability::IoManagement, true)?;

    // Allocate the RAMFS MMIO region so its pages are mapped.
    mm::__kcall_mmio_alloc(RAMFS_MMIO_TAG)?;

    // Query the region's base address and size.
    let info: ::sys::mm::MmioRegionInfo = mm::__kcall_mmio_info(RAMFS_MMIO_TAG)?;
    let base_addr: usize = info.base().into_raw_value();
    let size: usize = info.size();

    // Baseline read while the region is allocated. This must succeed: mmio_alloc maps the region
    // user-accessible. If this faulted, the process would die here (before the free step) and the
    // test would be inconclusive rather than a false pass.
    // SAFETY: `base_addr` is the first page of a live, user-accessible MMIO mapping.
    let before: u8 = unsafe { core::ptr::read_volatile(base_addr as *const u8) };

    ::syslog::info!(
        "test-mmio-free: allocated ramfs base={:#010x}, size={}, first_byte={:#04x}",
        base_addr,
        size,
        before,
    );

    // Detach the region via the public free kcall.
    mm::__kcall_mmio_free(RAMFS_MMIO_TAG)?;

    ::syslog::info!(
        "test-mmio-free: mmio_free returned; re-reading base to probe for a stale mapping",
    );

    // Post-free access. Correct behavior: the mapping was revoked -> this faults -> SIGSEGV default
    // action -> exit code 4. Buggy behavior: the read succeeds and we fall through.
    // SAFETY: intentional probe. If the mapping was correctly revoked this faults; if it survived
    // (the bug) it reads freed I/O memory.
    let after: u8 = unsafe { core::ptr::read_volatile(base_addr as *const u8) };

    // Reaching this point means the post-free read did NOT fault: the page-table entry survived
    // mmio_free. This is the CR-10 defect.
    ::syslog::info!(
        "test-mmio-free: BUGCR10 REPRODUCED - post-free read of freed MMIO region succeeded \
         (base={:#010x}, byte={:#04x}); mmio_free did NOT revoke the page-table entries",
        base_addr,
        after,
    );

    // Exit 0 (distinct from the correct exit code 4) to signal the stale mapping. Guard against the
    // slim chance the volatile read is elided by consuming `after`.
    if after == after.wrapping_add(1) {
        return Err(Error::new(ErrorCode::BadAddress, "unreachable"));
    }
    Ok(())
}
