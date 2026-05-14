// Verifies that the historical Family-2 bug (pre-9573fa1 `extract_from`
// ordering — clear-old before publish-new, with `Relaxed` clear) is no longer
// present in the production source. This is a static-source check: we read
// `src/hash_table/bucket.rs` and confirm that:
//   1. The "publish into the new bucket" call (`self.insert(..)`) appears
//      before the "store into from_writer.metadata.occupied_bitmap" call.
//   2. The store ordering on the source occupied bitmap is `Release` for INDEX
//      (not `Relaxed`).
//
// We don't reproduce the historical race because the fix is already merged.
// MC's regression-check is the equivalent of a unit test ensuring the legacy
// ordering would have triggered `MigrationVisibleEverywhere`. This binary
// gives a deterministic CI-style assertion that the production code keeps the
// fix in place — which is the actionable thing for current code.

use std::path::PathBuf;

fn main() {
    let bucket_rs: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "..",
        "..",
        "artifact",
        "scc",
        "src",
        "hash_table",
        "bucket.rs",
    ]
    .iter()
    .collect();

    let src = std::fs::read_to_string(&bucket_rs)
        .unwrap_or_else(|e| panic!("could not read {}: {e}", bucket_rs.display()));

    let extract_start = src
        .find("pub(crate) fn extract_from")
        .expect("extract_from not found in bucket.rs");
    let extract_end = src[extract_start..]
        .find("fn drop_entries")
        .expect("could not delimit extract_from");
    let extract_body = &src[extract_start..extract_start + extract_end];

    let publish_idx = extract_body
        .find("self.insert(data_block, hash, entry)")
        .expect("publish-new (`self.insert(..)`) call not found in extract_from");

    let clear_idx = extract_body
        .find(".occupied_bitmap\n                .store(occupied_bitmap & !(1_u32 << ")
        .or_else(|| {
            extract_body.find(".occupied_bitmap.store(occupied_bitmap & !(1_u32 << ")
        })
        .expect("clear-old (`occupied_bitmap.store(.., mo)`) call not found");

    println!("Locations within `extract_from`:");
    println!("  publish-new offset = {publish_idx}");
    println!("  clear-old   offset = {clear_idx}");

    if !(publish_idx < clear_idx) {
        eprintln!("REGRESSION: publish-new is NOT before clear-old in extract_from");
        std::process::exit(1);
    }

    let mo_decl = "let mo = if TYPE == INDEX { Release } else { Relaxed };";
    if !extract_body.contains(mo_decl) {
        eprintln!(
            "REGRESSION: source-clear ordering for INDEX is not `Release` (expected: `{mo_decl}`)"
        );
        std::process::exit(2);
    }

    println!("Family-2 (pre-9573fa1) ordering bug is FIXED in production code.");
    println!("  - publish-new precedes clear-old in extract_from()");
    println!("  - source occupied_bitmap clear uses `Release` for INDEX");
}
