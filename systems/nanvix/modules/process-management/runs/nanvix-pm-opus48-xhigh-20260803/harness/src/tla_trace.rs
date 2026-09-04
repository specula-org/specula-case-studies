// Copyright(c) The Maintainers of Nanvix.
// Licensed under the MIT License.

//==================================================================================================
// TLA+ Trace Emission (Specula harness)
//==================================================================================================
//
// Emits one NDJSON line per traced kernel PM event to the kernel console, so that the standalone
// UserVM's captured stdout can be post-processed into a `.ndjson` trace and replayed against
// `spec/Trace.tla`.
//
// Every emitted line has the form:
//
//     @@TLA@@ {"action":"<ActionName>", ...}
//
// The `@@TLA@@ ` marker lets `run.sh` extract trace lines from the interleaved kernel log. The
// payload after the marker is a single-line JSON object matching the schema expected by `Trace.tla`
// (see `instrumentation-spec.md`): the action name, its recorded arguments, the
// implementation-observable post-state fields the wrapper validates, and the `tlive`/`plive`
// accounting counters that are checked on every event. NOTE: unlike the general Specula default,
// this schema does NOT carry a `tag` or `ts` field — `Trace.tla` deserializes each line with
// `ndJsonDeserialize`, dispatches on `Lg.action`, and advances a single linear cursor `l`.
//
// IMPORTANT — the kernel slab heap rejects any single allocation larger than 512 bytes
// (`mm::kheap`). A trace line is typically 100–300 bytes, but to keep every allocation small the
// JSON is *streamed* field-by-field straight into the kernel log via [`KlogWriter`] (an
// [`fmt::Write`] adapter over `crate::klog::puts`), so no large intermediate `String` is ever
// built. Output bypasses log-level gating and is flushed at end-of-line so lines are delivered even
// when the log level would otherwise suppress logging.
//
// This module is compiled only under the `test` feature and performs no protocol logic; it is a
// pure I/O + JSON-formatting sink driven by the real state-transition scenarios in
// `crate::pm::process::state::tla_world`.

#![allow(dead_code)]

use ::core::fmt::{
    self,
    Write,
};

/// Marker prefix identifying a trace line in the captured kernel console stream.
const MARKER: &str = "@@TLA@@ ";

/// Marker prefix identifying a scenario boundary in the captured kernel console stream. `run.sh`
/// splits the combined stream into one `.ndjson` file per scenario at these boundaries.
const SCENARIO_MARKER: &str = "@@SCENARIO@@ ";

///
/// # Description
///
/// An [`fmt::Write`] adapter that streams every written fragment straight to the kernel log via
/// `crate::klog::puts`. Because each fragment is written independently, building a JSON line through
/// `write!(...)` never allocates a buffer bigger than the fragment being formatted, which keeps
/// every allocation well under the kernel heap's 512-byte slab limit.
///
pub struct KlogWriter;

impl fmt::Write for KlogWriter {
    fn write_str(&mut self, s: &str) -> fmt::Result {
        // SAFETY: the kernel is single-core with interrupts disabled during the in-kernel test
        // phase, so there is no concurrent access to the log device; the backing storage is
        // installed early in boot, well before the PM test scenarios run.
        unsafe { crate::klog::puts(s) };
        Ok(())
    }
}

///
/// # Description
///
/// Emits one completed NDJSON trace line. The closure writes the JSON object body directly into the
/// provided [`KlogWriter`]; the marker prefix, trailing newline, and flush are handled here.
///
/// # Parameters
///
/// - `body`: Writes the JSON object (e.g. `{"action":...}`) into the streaming writer.
///
pub fn emit_line<F>(body: F)
where
    F: FnOnce(&mut KlogWriter) -> fmt::Result,
{
    // SAFETY: see `KlogWriter::write_str`.
    unsafe { crate::klog::puts(MARKER) };
    let mut w: KlogWriter = KlogWriter;
    let _ = body(&mut w);
    // SAFETY: see `KlogWriter::write_str`.
    unsafe {
        crate::klog::puts("\n");
        crate::klog::flush();
    }
}

///
/// # Description
///
/// Emits a scenario-boundary marker. All trace lines emitted after this call (until the next
/// marker) belong to the named scenario.
///
/// # Parameters
///
/// - `name`: Scenario name (becomes the `.ndjson` file stem).
///
pub fn emit_marker(name: &str) {
    // SAFETY: see `KlogWriter::write_str`.
    unsafe {
        crate::klog::puts(SCENARIO_MARKER);
        crate::klog::puts(name);
        crate::klog::puts("\n");
        crate::klog::flush();
    }
}

//==================================================================================================
// JSON streaming helpers
//==================================================================================================
//
// The kernel has no serde; these helpers stream the small, fixed-shape JSON the trace schema needs.
// Object keys are always known-safe identifiers, so only string *values* are escaped.

/// Streams a JSON string literal `"value"`, escaping the characters that can appear in the symbolic
/// model values.
pub fn write_str_lit(w: &mut KlogWriter, value: &str) -> fmt::Result {
    w.write_char('"')?;
    for ch in value.chars() {
        match ch {
            '"' => w.write_str("\\\"")?,
            '\\' => w.write_str("\\\\")?,
            c => w.write_char(c)?,
        }
    }
    w.write_char('"')
}
