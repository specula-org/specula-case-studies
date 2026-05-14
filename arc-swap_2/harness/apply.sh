#!/usr/bin/env bash
# Apply trace instrumentation to the arc-swap artifact.
#
# Idempotent: starts by `git checkout -- .` to reset any prior patches.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ART="$(cd "$HERE/../../artifact/arc-swap" && pwd)"

echo "[apply] resetting artifact to clean state"
( cd "$ART" && git checkout -- . )
rm -f "$ART/src/tla_trace.rs"
rm -f "$ART/tests/tla_trace_scenarios.rs"

echo "[apply] installing trace module"
cp "$HERE/src/tla_trace.rs" "$ART/src/tla_trace.rs"

# ---------------------------------------------------------------------------
# lib.rs:
#   1. add `pub mod tla_trace;`
#   2. emit WriterSwap right after self.ptr.swap
#   3. emit DropArcSwap from ArcSwapAny::drop
# ---------------------------------------------------------------------------
echo "[apply] patching src/lib.rs"
python3 - "$ART/src/lib.rs" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()

# 1. Insert `pub mod tla_trace;` right after `mod debt;` line.
src = src.replace(
    "mod debt;\n",
    "mod debt;\npub mod tla_trace;\n",
    1,
)

# 2. Inject WriterSwap call after the swap line.
old = "        let old = self.ptr.swap(new, Ordering::SeqCst);\n"
new = (
    "        let old = self.ptr.swap(new, Ordering::SeqCst);\n"
    "        crate::tla_trace::emit_writer_swap(new as usize);\n"
)
assert old in src, "WriterSwap anchor not found"
src = src.replace(old, new, 1)

# 3. Inject DropArcSwap after T::dec(ptr) inside ArcSwapAny::Drop.
old = "            T::dec(ptr);\n        }\n    }\n"
new = (
    "            T::dec(ptr);\n"
    "            crate::tla_trace::emit_drop_arc_swap();\n"
    "        }\n    }\n"
)
assert old in src, "DropArcSwap anchor not found"
src = src.replace(old, new, 1)

open(path, "w").write(src)
PY

# ---------------------------------------------------------------------------
# strategy/hybrid.rs: instrument fast-path attempt() and HybridProtection::drop
# ---------------------------------------------------------------------------
echo "[apply] patching src/strategy/hybrid.rs"
python3 - "$ART/src/strategy/hybrid.rs" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()

# attempt(): emit ReaderFastLoad after ptr load
old = (
    "        // Relaxed is good enough here, see the Acquire below\n"
    "        let ptr = storage.load(Relaxed);\n"
)
new = (
    "        // Relaxed is good enough here, see the Acquire below\n"
    "        let ptr = storage.load(Relaxed);\n"
    "        crate::tla_trace::emit_reader_fast_load(ptr as usize);\n"
)
assert old in src, "ReaderFastLoad anchor not found"
src = src.replace(old, new, 1)

# attempt(): emit ReaderFastConfirmLoad after confirm load
old = (
    "        // SeqCst to make sure the storage vs. the debt are well ordered.\n"
    "        let confirm = storage.load(SeqCst);\n"
)
new = (
    "        // SeqCst to make sure the storage vs. the debt are well ordered.\n"
    "        let confirm = storage.load(SeqCst);\n"
    "        crate::tla_trace::emit_reader_fast_confirm_load(confirm as usize);\n"
)
assert old in src, "ReaderFastConfirmLoad anchor not found"
src = src.replace(old, new, 1)

# attempt(): emit ReaderFastBranchHit on equality, ReaderFastResolve on each leg
old = (
    "        if ptr == confirm {\n"
    "            // Successfully got a debt\n"
    "            // NOTE: we *must* use `confirm` here instead of `ptr`. The address may compare equal,\n"
    "            // but they could have different provenance, if the pointer is freed and then\n"
    "            // subsequently reused.\n"
    "            Some(unsafe { Self::new(confirm, Some(debt)) })\n"
    "        } else if debt.pay::<T>(ptr) {\n"
    "            // It changed in the meantime, we return the debt (that is on the outdated pointer,\n"
    "            // possibly destroyed) and fail.\n"
    "            None\n"
    "        } else {\n"
    "            // It changed in the meantime, but the debt for the previous pointer was already paid\n"
    "            // for by someone else, so we are fine using it.\n"
    "            Some(unsafe { Self::new(ptr, None) })\n"
    "        }\n"
)
new = (
    "        if ptr == confirm {\n"
    "            crate::tla_trace::emit_reader_fast_branch_hit();\n"
    "            // Successfully got a debt\n"
    "            // NOTE: we *must* use `confirm` here instead of `ptr`. The address may compare equal,\n"
    "            // but they could have different provenance, if the pointer is freed and then\n"
    "            // subsequently reused.\n"
    "            Some(unsafe { Self::new(confirm, Some(debt)) })\n"
    "        } else if debt.pay::<T>(ptr) {\n"
    "            crate::tla_trace::emit_reader_fast_resolve();\n"
    "            // It changed in the meantime, we return the debt (that is on the outdated pointer,\n"
    "            // possibly destroyed) and fail.\n"
    "            None\n"
    "        } else {\n"
    "            crate::tla_trace::emit_reader_fast_resolve();\n"
    "            // It changed in the meantime, but the debt for the previous pointer was already paid\n"
    "            // for by someone else, so we are fine using it.\n"
    "            Some(unsafe { Self::new(ptr, None) })\n"
    "        }\n"
)
assert old in src, "ReaderFastBranchHit/Resolve anchor not found"
src = src.replace(old, new, 1)

# Drop for HybridProtection: emit DropGuard at top
old = (
    "impl<T: RefCnt> Drop for HybridProtection<T> {\n"
    "    #[inline]\n"
    "    fn drop(&mut self) {\n"
    "        match self.debt.take() {\n"
)
new = (
    "impl<T: RefCnt> Drop for HybridProtection<T> {\n"
    "    #[inline]\n"
    "    fn drop(&mut self) {\n"
    "        crate::tla_trace::emit_drop_guard();\n"
    "        match self.debt.take() {\n"
)
assert old in src, "DropGuard anchor not found"
src = src.replace(old, new, 1)

open(path, "w").write(src)
PY

# ---------------------------------------------------------------------------
# debt/fast.rs: emit ReaderFastSlotAcquire after slot.0.swap(ptr, SeqCst)
# ---------------------------------------------------------------------------
echo "[apply] patching src/debt/fast.rs"
python3 - "$ART/src/debt/fast.rs" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()

old = (
    "                let old = slot.0.swap(ptr, SeqCst);\n"
    "                debug_assert_eq!(Debt::NONE, old);\n"
)
new = (
    "                let old = slot.0.swap(ptr, SeqCst);\n"
    "                crate::tla_trace::emit_reader_fast_slot_acquire(i, 8);\n"
    "                debug_assert_eq!(Debt::NONE, old);\n"
)
assert old in src, "ReaderFastSlotAcquire anchor not found"
src = src.replace(old, new, 1)

open(path, "w").write(src)
PY

# ---------------------------------------------------------------------------
# debt/list.rs:
#   - emit WriterTraverseLoad in Node::traverse (gated by in_pay_all)
#   - emit WriterReserveNode after fetch_add in reserve_writer (gated)
#   - emit WriterReleaseNode after fetch_sub in NodeReservation::drop (gated)
#   - register the node when Node::get returns it to a thread
# ---------------------------------------------------------------------------
echo "[apply] patching src/debt/list.rs"
python3 - "$ART/src/debt/list.rs" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()

# WriterTraverseLoad — emit right after LIST_HEAD.load(SeqCst).
old = (
    "        let mut current = unsafe { LIST_HEAD.load(SeqCst).as_ref() };\n"
)
new = (
    "        let mut current = unsafe { LIST_HEAD.load(SeqCst).as_ref() };\n"
    "        crate::tla_trace::emit_writer_traverse_load();\n"
)
assert old in src, "WriterTraverseLoad anchor not found"
src = src.replace(old, new, 1)

# WriterReleaseNode — emit at the end of NodeReservation::drop.
old = (
    "impl Drop for NodeReservation<'_> {\n"
    "    fn drop(&mut self) {\n"
    "        self.0.active_writers.fetch_sub(1, Release);\n"
    "    }\n"
    "}\n"
)
new = (
    "impl Drop for NodeReservation<'_> {\n"
    "    fn drop(&mut self) {\n"
    "        let prev = self.0.active_writers.fetch_sub(1, Release);\n"
    "        crate::tla_trace::emit_writer_release_node(self.0 as *const _ as usize, prev.saturating_sub(1));\n"
    "    }\n"
    "}\n"
)
assert old in src, "WriterReleaseNode anchor not found"
src = src.replace(old, new, 1)

# WriterReserveNode — emit at end of reserve_writer.
old = (
    "    pub fn reserve_writer(&self) -> NodeReservation<'_> {\n"
    "        self.active_writers.fetch_add(1, Acquire);\n"
    "        NodeReservation(self)\n"
    "    }\n"
)
new = (
    "    pub fn reserve_writer(&self) -> NodeReservation<'_> {\n"
    "        let prev = self.active_writers.fetch_add(1, Acquire);\n"
    "        crate::tla_trace::emit_writer_reserve_node(self as *const _ as usize, prev + 1);\n"
    "        NodeReservation(self)\n"
    "    }\n"
)
assert old in src, "WriterReserveNode anchor not found"
src = src.replace(old, new, 1)

# Register node owner — at the success exit of Node::get (claim path)
old = (
    "                .compare_exchange(NODE_UNUSED, NODE_USED, SeqCst, SeqCst)\n"
    "                .is_ok()\n"
    "            {\n"
    "                Some(node)\n"
    "            } else {\n"
    "                None\n"
    "            }\n"
    "        })\n"
)
new = (
    "                .compare_exchange(NODE_UNUSED, NODE_USED, SeqCst, SeqCst)\n"
    "                .is_ok()\n"
    "            {\n"
    "                crate::tla_trace::register_node(node as *const _ as usize);\n"
    "                Some(node)\n"
    "            } else {\n"
    "                None\n"
    "            }\n"
    "        })\n"
)
assert old in src, "register_node (claim) anchor not found"
src = src.replace(old, new, 1)

# Register node owner — also on the freshly-created path
old = (
    "                ) {\n"
    "                    head = old;\n"
    "                } else {\n"
    "                    return node;\n"
    "                }\n"
)
new = (
    "                ) {\n"
    "                    head = old;\n"
    "                } else {\n"
    "                    crate::tla_trace::register_node(node as *const _ as usize);\n"
    "                    return node;\n"
    "                }\n"
)
assert old in src, "register_node (create) anchor not found"
src = src.replace(old, new, 1)

open(path, "w").write(src)
PY

# ---------------------------------------------------------------------------
# debt/mod.rs: instrument pay_all
# ---------------------------------------------------------------------------
echo "[apply] patching src/debt/mod.rs"
python3 - "$ART/src/debt/mod.rs" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()

old = (
    "        LocalNode::with(|local| {\n"
    "            let val = unsafe { T::from_ptr(ptr) };\n"
    "            // Pre-pay one ref count that can be safely put into a debt slot to pay it.\n"
    "            T::inc(&val);\n"
    "\n"
    "            Node::traverse::<(), _>(|node| {\n"
    "                // Make the cooldown trick know we are poking into this node.\n"
    "                let _reservation = node.reserve_writer();\n"
    "\n"
    "                local.help(node, storage_addr, &replacement);\n"
    "\n"
    "                let all_slots = node\n"
    "                    .fast_slots()\n"
    "                    .chain(core::iter::once(node.helping_slot()));\n"
    "                for slot in all_slots {\n"
    "                    // Note: Release is enough even here. That makes sure the increment is\n"
    "                    // visible to whoever might acquire on this slot and can't leak below this.\n"
    "                    // And we are the ones doing decrements anyway.\n"
    "                    if slot.pay::<T>(ptr) {\n"
    "                        // Pre-pay one more, for another future slot\n"
    "                        T::inc(&val);\n"
    "                    }\n"
    "                }\n"
    "\n"
    "                None\n"
    "            });\n"
    "            // Implicit dec by dropping val in here, pair for the above\n"
    "        })\n"
)
new = (
    "        let _payall_scope = crate::tla_trace::PayAllScope::enter();\n"
    "        LocalNode::with(|local| {\n"
    "            let val = unsafe { T::from_ptr(ptr) };\n"
    "            // Pre-pay one ref count that can be safely put into a debt slot to pay it.\n"
    "            T::inc(&val);\n"
    "            crate::tla_trace::emit_writer_pay_init();\n"
    "\n"
    "            Node::traverse::<(), _>(|node| {\n"
    "                // Make the cooldown trick know we are poking into this node.\n"
    "                let _reservation = node.reserve_writer();\n"
    "\n"
    "                local.help(node, storage_addr, &replacement);\n"
    "                crate::tla_trace::emit_writer_help_node();\n"
    "\n"
    "                let all_slots = node\n"
    "                    .fast_slots()\n"
    "                    .chain(core::iter::once(node.helping_slot()));\n"
    "                let node_ptr = node as *const _ as usize;\n"
    "                for (slot_idx, slot) in all_slots.enumerate() {\n"
    "                    // Note: Release is enough even here. That makes sure the increment is\n"
    "                    // visible to whoever might acquire on this slot and can't leak below this.\n"
    "                    // And we are the ones doing decrements anyway.\n"
    "                    if slot.pay::<T>(ptr) {\n"
    "                        // Pre-pay one more, for another future slot\n"
    "                        T::inc(&val);\n"
    "                    }\n"
    "                    crate::tla_trace::emit_writer_scan_slot(node_ptr, slot_idx);\n"
    "                }\n"
    "\n"
    "                None\n"
    "            });\n"
    "            // Implicit dec by dropping val in here, pair for the above\n"
    "            crate::tla_trace::emit_writer_pay_done();\n"
    "        })\n"
)
assert old in src, "pay_all anchor not found"
src = src.replace(old, new, 1)

open(path, "w").write(src)
PY

# ---------------------------------------------------------------------------
# Copy test scenarios into artifact's tests directory so cargo test picks them up.
# ---------------------------------------------------------------------------
echo "[apply] copying test scenarios"
cp "$HERE/tests/tla_trace_scenarios.rs" "$ART/tests/tla_trace_scenarios.rs"

echo "[apply] done."
