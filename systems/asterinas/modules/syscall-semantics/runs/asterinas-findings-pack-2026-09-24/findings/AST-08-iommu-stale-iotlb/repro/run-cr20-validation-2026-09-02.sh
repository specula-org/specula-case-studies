#!/usr/bin/env bash
# Runs the CR-20 (AST-08) ktest once under IOMMU + edu device with vtd tracing.
set -u
S=${SCRATCH:-/tmp/claude-1000/-home-chin39-Documents-play-specula-profile/fdddff6c-e100-4393-bfca-70a770b0b10b/scratchpad}
WT=$S/aster-pin; L=$S/logs/cr20; mkdir -p $L
cp $S/OSDK.cr20.toml $WT/ostd/OSDK.toml
cp $S/harness/cr20_repro.rs $WT/ostd/src/cr20_repro.rs
python3 - "$WT/ostd/src/lib.rs" <<PY
import pathlib,sys
p=pathlib.Path(sys.argv[1]); t=p.read_text()
add="#[cfg(ktest)]\npub(crate) mod cr20_repro;\n"
if "cr20_repro" not in t:
    a="#[cfg(ktest)]\nmod test {"
    assert a in t
    t=t.replace(a, add+a, 1); p.write_text(t)
print("cr20 registered")
PY
grep -nE "fn |#\[ktest\]" $WT/ostd/src/cr20_repro.rs | grep -A1 "ktest" | head
T=$(grep -A1 "#\[ktest\]" $WT/ostd/src/cr20_repro.rs | grep -oE "fn [a-z0-9_]+" | head -1 | cut -d" " -f2)
echo "=== cr20 test fn: $T start $(date -u +%FT%TZ)"
( cd $WT/ostd && SMP=2 timeout 3000 $WT/osdk/target/debug/cargo-osdk osdk test "cr20_repro::$T" --target-arch x86_64 ) > $L/$T.log 2>&1
echo "=== exit=$? end $(date -u +%FT%TZ)"
grep -aE "^CR20\||CR20\||test result|panicked at|iommu|vtd_" $L/$T.log | head -60
echo "--- vtd event counts ---"; for e in vtd_iotlb_page_update vtd_iotlb_page_hit vtd_iotlb_reset vtd_inv_desc_iotlb_global vtd_inv_desc_iotlb_domain vtd_inv_desc_iotlb_pages vtd_dmar_fault; do printf "%-28s %s\n" $e "$(grep -ac "$e" $L/$T.log)"; done
echo CR20_DRIVER_DONE
