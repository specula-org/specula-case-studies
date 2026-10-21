#!/usr/bin/env python3
"""Patch the private container's pinned alloc source, never the host sysroot."""
from pathlib import Path
import hashlib
import subprocess
import sys

path = Path(subprocess.check_output(['rustc', '--print', 'sysroot'], text=True).strip()) / 'lib/rustlib/src/rust/library/alloc/src/sync.rs'
current_text = path.read_text()
expected = '2e11d0c0eb5ebabdbb3d045ed5b241869feeacff6eae9a8869bf48ebcf87eef1'
original_path = Path('/harness/evidence/alloc-original.rs')
if hashlib.sha256(current_text.encode()).hexdigest() == expected:
    original_text = current_text
elif original_path.is_file() and hashlib.sha256(original_path.read_bytes()).hexdigest() == expected:
    original_text = original_path.read_text()
else:
    raise SystemExit('no pinned original alloc source for exact patch verification')
text = original_text

def change(old, new):
    global text
    assert text.count(old) == 1, (old[:80], text.count(old))
    text = text.replace(old, new)

change('        let old_size = self.inner().strong.fetch_add(1, Relaxed);', '''        let trace_identity = specula_identity(Self::as_ptr(self) as *const () as usize);
        let trace_start = specula_stamp();
        let old_size = self.inner().strong.fetch_add(1, Relaxed);
        specula_observe(1, trace_identity, old_size + 1, trace_start);''')
change('        if self.inner().strong.fetch_sub(1, Release) != 1 {', '''        let trace_identity = specula_identity(Self::as_ptr(self) as *const () as usize);
        let trace_start = specula_stamp();
        let trace_old = self.inner().strong.fetch_sub(1, Release);
        specula_observe(2, trace_identity, trace_old - 1, trace_start);
        if trace_old != 1 {''')
change('        // We cannot use `get_mut_unchecked` here, because `self.alloc` is borrowed.\n        unsafe { ptr::drop_in_place(&mut (*self.ptr.as_ptr()).data) };', '''        // We cannot use `get_mut_unchecked` here, because `self.alloc` is borrowed.
        let trace_identity = specula_identity(Self::as_ptr(self) as *const () as usize);
        unsafe { ptr::drop_in_place(&mut (*self.ptr.as_ptr()).data) };
        specula_observe(4, trace_identity, 0, specula_stamp());''')
change('        if self.inner()?.strong.try_update(Acquire, Relaxed, checked_increment).is_ok() {', '''        let trace_identity = specula_identity(self.as_ptr() as *const () as usize);
        let trace_start = specula_stamp();
        let trace_result = self.inner()?.strong.try_update(Acquire, Relaxed, checked_increment);
        specula_observe(3, trace_identity,
            match trace_result { Ok(previous) => previous + 1, Err(observed) => observed }, trace_start);
        if trace_result.is_ok() {''')
text += '''
// Only build-std for the harness kernel uses these hooks. Host tools retain
// their installed standard library and do not link against the kernel.
#[inline]
fn specula_stamp() -> u64 {
    #[cfg(all(target_arch = "x86_64", target_os = "none"))]
    unsafe {
        core::arch::x86_64::_mm_lfence();
        let t = core::arch::x86_64::_rdtsc();
        core::arch::x86_64::_mm_lfence();
        t
    }
    #[cfg(not(all(target_arch = "x86_64", target_os = "none")))]
    { 0 }
}
#[inline]
fn specula_identity(address: usize) -> usize {
    #[cfg(all(target_arch = "x86_64", target_os = "none"))]
    unsafe {
        unsafe extern "C" { fn __specula_arc_identity(address: usize) -> usize; }
        __specula_arc_identity(address)
    }
    #[cfg(not(all(target_arch = "x86_64", target_os = "none")))]
    { let _ = address; 0 }
}
#[inline]
fn specula_observe(operation: usize, identity: usize, count: usize, start: u64) {
    #[cfg(all(target_arch = "x86_64", target_os = "none"))]
    unsafe {
        unsafe extern "C" { fn __specula_arc_observe(operation: usize, identity: usize, count: usize, start: u64); }
        __specula_arc_observe(operation, identity, count, start);
    }
    #[cfg(not(all(target_arch = "x86_64", target_os = "none")))]
    let _ = (operation, identity, count, start);
}
'''
if current_text not in (original_text, text):
    raise SystemExit('installed alloc hooks differ from this exact reviewed version')
original_path.write_text(original_text)
if current_text != text:
    path.write_text(text)
Path('/harness/evidence/alloc-instrumented.rs').write_text(text)
print(hashlib.sha256(text.encode()).hexdigest(), path)
