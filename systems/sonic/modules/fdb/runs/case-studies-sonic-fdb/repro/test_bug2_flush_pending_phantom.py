#!/usr/bin/env python3
"""
Bug 2 Reproduction: Phantom FDB Entries After VLAN Flush (is_flush_pending Not Set)

This test faithfully models the FdbOrch flush state machine from sonic-swss and
replays the MC counterexample showing that flushFdbByVlan() never sets
is_flush_pending on matching entries, so handleSyncdFlushNotif() skips all of
them, leaving phantom entries in m_entries that don't exist in hardware.

The modeled code paths (with file:line references):
  - FdbOrch::flushFDBEntries()      (fdborch.cpp:1198-1255) — DOES set is_flush_pending
  - FdbOrch::flushFdbByVlan()       (fdborch.cpp:1256-1290) — does NOT set is_flush_pending
  - FdbOrch::handleSyncdFlushNotif() (fdborch.cpp:227-295)  — checks is_flush_pending
  - FdbOrch::clearFdbEntry()        (fdborch.cpp:200-222)   — removes entry from m_entries

MC Config: MC_hunt_flush_phantom.cfg
Invariant: NoPhantomAfterVlanFlush
Counterexample: 5 states
"""

import sys

# ─── Faithful model of FDB state ───

class FdbEntry:
    def __init__(self, mac, bv_id):
        self.mac = mac
        self.bv_id = bv_id
    def __eq__(self, other):
        return self.mac == other.mac and self.bv_id == other.bv_id
    def __hash__(self):
        return hash((self.mac, self.bv_id))
    def __repr__(self):
        return f"({self.mac}, vlan_oid={hex(self.bv_id)})"

class FdbData:
    def __init__(self, bridge_port_id, port_name, origin="LEARN",
                 sai_fdb_type="DYNAMIC", is_flush_pending=False):
        self.bridge_port_id = bridge_port_id
        self.port_name = port_name
        self.origin = origin
        self.sai_fdb_type = sai_fdb_type
        self.is_flush_pending = is_flush_pending
    def __repr__(self):
        return (f"FdbData(port={self.port_name}, type={self.sai_fdb_type}, "
                f"pending={self.is_flush_pending})")

class FdbOrch:
    """Models fdborch.cpp flush paths"""
    def __init__(self):
        self.m_entries = {}  # FdbEntry -> FdbData

    def learn(self, mac, bv_id, bridge_port_id, port_name):
        """Simulates SAI_FDB_EVENT_LEARNED path (fdborch.cpp:356-413)"""
        entry = FdbEntry(mac, bv_id)
        self.m_entries[entry] = FdbData(bridge_port_id, port_name)

    def flushFDBEntries(self, bridge_port_oid, vlan_oid):
        """fdborch.cpp:1198-1255 — THE CORRECT IMPLEMENTATION

        Lines 1242-1253: iterates m_entries and sets is_flush_pending=true
        on all matching entries. This is the right behavior.
        """
        count = 0
        for entry, data in self.m_entries.items():
            match = False
            if (bridge_port_oid is not None and
                    data.bridge_port_id == bridge_port_oid):
                match = True
            if vlan_oid is not None and entry.bv_id == vlan_oid:
                match = True
            if match:
                data.is_flush_pending = True
                count += 1
        return count

    def flushFdbByVlan(self, vlan_oid):
        """fdborch.cpp:1256-1290 — THE BUGGY FUNCTION

        Sends SAI flush for the VLAN but NEVER sets is_flush_pending on
        matching entries. Compare with flushFDBEntries() lines 1242-1253.

        The entire function body (lines 1256-1290):
          1. Gets vlan port from alias
          2. Builds SAI flush attrs (BV_ID + ENTRY_TYPE_DYNAMIC)
          3. Calls sai_fdb_api->flush_fdb_entries()
          4. Returns  ← NO is_flush_pending = true anywhere!
        """
        # SAI flush request sent (async, fire-and-forget)
        # ... but NO iteration over m_entries to set is_flush_pending
        pass  # Bug: nothing happens to m_entries

    def handleSyncdFlushNotif_byVlan(self, bv_id, sai_fdb_type="DYNAMIC"):
        """fdborch.cpp:263-278 — FLUSH based on BV_ID

        Lines 265-278:
          for (auto itr = m_entries.begin(); itr != m_entries.end();)
          {
              auto curr = itr++;
              if (curr->first.bv_id == bv_id)
              {
                  if (curr->second.sai_fdb_type == sai_fdb_type &&
                      ... && curr->second.is_flush_pending)  // ← THE CHECK
                  {
                      clearFdbEntry(curr->first);
                  }
              }
          }
        """
        cleared = []
        skipped = []
        to_remove = []
        for entry, data in self.m_entries.items():
            if entry.bv_id == bv_id:
                if (data.sai_fdb_type == sai_fdb_type and
                        data.is_flush_pending):  # ← is_flush_pending check
                    to_remove.append(entry)
                    cleared.append(entry)
                else:
                    skipped.append((entry, data.is_flush_pending))

        for entry in to_remove:
            del self.m_entries[entry]

        return cleared, skipped

    def clearFdbEntry(self, entry):
        """fdborch.cpp:200-222"""
        if entry in self.m_entries:
            del self.m_entries[entry]


def main():
    print("=" * 70)
    print("Bug 2: Phantom FDB Entries After VLAN Flush")
    print("       (flushFdbByVlan missing is_flush_pending)")
    print("=" * 70)
    print()

    fdb = FdbOrch()

    VLAN_OID = 0x26000000000796
    BP_OID = 0x3a000000002c33
    MAC1 = "7c:fe:90:12:22:ec"
    MAC2 = "aa:bb:cc:dd:ee:ff"

    # ─── MC counterexample replay (5 states) ───

    print("State 1 (Init): Empty state")
    print(f"  m_entries: {{}}")
    print()

    print("State 2: Learn FDB entry (MAC1)")
    fdb.learn(MAC1, VLAN_OID, BP_OID, "Ethernet0")
    print(f"  Learned: ({MAC1}, Vlan100) on Ethernet0")
    print(f"  m_entries: {dict(fdb.m_entries)}")
    print()

    print("State 3: Learn FDB entry (MAC2)")
    fdb.learn(MAC2, VLAN_OID, BP_OID, "Ethernet0")
    print(f"  Learned: ({MAC2}, Vlan100) on Ethernet0")
    print(f"  m_entries count: {len(fdb.m_entries)}")
    print()

    # ─── The bug: flushFdbByVlan does NOT set is_flush_pending ───

    print("State 4: STP triggers flushFdbByVlan(Vlan100)")
    print("  Calling flushFdbByVlan() — this sends SAI flush but does NOT")
    print("  set is_flush_pending on any entries.")
    print()
    print("  COMPARE the two flush functions:")
    print()

    # Show what flushFDBEntries would do (correct)
    print("  flushFDBEntries() (fdborch.cpp:1242-1253) — CORRECT:")
    print("    for (auto it = m_entries.begin(); ...)")
    print("      if (vlan_oid != NULL && it->first.bv_id == vlan_oid)")
    print("        it->second.is_flush_pending = true;  // ← SETS FLAG")
    print()
    print("  flushFdbByVlan() (fdborch.cpp:1256-1290) — BUGGY:")
    print("    sai_fdb_api->flush_fdb_entries(gSwitchId, 2, vlan_attr);")
    print("    return;  // ← NO is_flush_pending = true ANYWHERE")
    print()

    fdb.flushFdbByVlan(VLAN_OID)

    # Check is_flush_pending on all entries
    print("  After flushFdbByVlan():")
    for entry, data in fdb.m_entries.items():
        print(f"    {entry}: is_flush_pending = {data.is_flush_pending}")
    print()

    # ─── ASIC has flushed the entries (hardware side) ───
    print("  [ASIC side: SAI flushed all dynamic entries for Vlan100]")
    print("  [Hardware now has 0 entries for this VLAN]")
    asic_entries = set()  # ASIC is now empty for this VLAN
    print()

    # ─── Flush notification arrives ───
    print("State 5: SAI_FDB_EVENT_FLUSHED notification arrives")
    print("  handleSyncdFlushNotif checks is_flush_pending on each entry...")
    cleared, skipped = fdb.handleSyncdFlushNotif_byVlan(VLAN_OID)
    print(f"  Cleared entries: {cleared}")
    print(f"  Skipped entries (is_flush_pending=False):")
    for entry, pending in skipped:
        print(f"    {entry}: is_flush_pending={pending} → SKIPPED")
    print()

    # ─── Check invariant ───
    print("=" * 70)
    print("INVARIANT CHECK: NoPhantomAfterVlanFlush")
    print("  After flush notification, m_entries should not contain entries")
    print("  that no longer exist in ASIC (phantom entries)")
    print()
    m_keys = set((e.mac, e.bv_id) for e in fdb.m_entries)
    phantoms = m_keys - asic_entries
    print(f"  m_entries: {m_keys}")
    print(f"  ASIC entries: {asic_entries}")
    print(f"  Phantom entries (in SW but not in HW): {phantoms}")
    print()

    if phantoms:
        print("  >>> INVARIANT VIOLATED: NoPhantomAfterVlanFlush <<<")
        print()
        print(f"  {len(phantoms)} phantom entries remain in m_entries")
        print("  These entries will never be cleaned up because:")
        print("  1. flushFdbByVlan() never set is_flush_pending=true")
        print("  2. handleSyncdFlushNotif() skips entries with pending=false")
        print("  3. No other code path clears these phantom entries")
        print()
        print("  Root cause: fdborch.cpp:1256-1290 (flushFdbByVlan)")
        print("    Missing: iteration over m_entries to set is_flush_pending=true")
        print("    Compare: fdborch.cpp:1242-1253 (flushFDBEntries) which DOES set it")
        print()
        print("  Added in: commit 5a8d403d (PVST feature support, #3425)")
        print("  The is_flush_pending mechanism was already in place (commit 8dae3564)")
        print("  but the new flushFdbByVlan function missed it.")
        print()

        # ─── Now show the correct behavior for comparison ───
        print("-" * 70)
        print("COMPARISON: Same scenario with flushFDBEntries() (correct path)")
        print()
        fdb2 = FdbOrch()
        fdb2.learn(MAC1, VLAN_OID, BP_OID, "Ethernet0")
        fdb2.learn(MAC2, VLAN_OID, BP_OID, "Ethernet0")
        print(f"  Before flush: {len(fdb2.m_entries)} entries")
        count = fdb2.flushFDBEntries(None, VLAN_OID)
        print(f"  flushFDBEntries set is_flush_pending on {count} entries")
        for entry, data in fdb2.m_entries.items():
            print(f"    {entry}: is_flush_pending = {data.is_flush_pending}")
        cleared2, skipped2 = fdb2.handleSyncdFlushNotif_byVlan(VLAN_OID)
        print(f"  After handleSyncdFlushNotif: cleared {len(cleared2)}, skipped {len(skipped2)}")
        print(f"  m_entries remaining: {len(fdb2.m_entries)}")
        print(f"  Phantoms: {len(fdb2.m_entries)} (expected: 0)")
        print()
        print("BUG REPRODUCED")
        return 0
    else:
        print("  No phantoms — bug NOT reproduced")
        return 1


if __name__ == "__main__":
    sys.exit(main())
