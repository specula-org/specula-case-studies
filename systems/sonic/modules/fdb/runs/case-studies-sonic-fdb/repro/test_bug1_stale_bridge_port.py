#!/usr/bin/env python3
"""
Bug 1 Reproduction: Stale Bridge Port OID Silently Drops FDB Events

This test faithfully models the FdbOrch/PortsOrch state machine from sonic-swss
and replays the MC counterexample showing that removeBridgePort() erases the
bridge port from saiOidToAlias BEFORE the async flush notification arrives,
causing subsequent LEARNED/AGED events to be silently dropped.

The modeled code paths (with file:line references):
  - PortsOrch::addBridgePort()     (portsorch.cpp:7256-7308)
  - PortsOrch::removeBridgePort()  (portsorch.cpp:7310-7388)
  - FdbOrch::update()              (fdborch.cpp:297-346)
  - FdbOrch::flushFDBEntries()     (fdborch.cpp:1198-1255)

MC Config: MC_hunt_stale_bp.cfg
Invariant: FdbAsicConsistency — asicEntries ⊆ DOMAIN mEntries
Historical: sonic-buildimage#26531 (75-min production blackhole, 1046 dropped events)
"""

import sys

# ─── Faithful model of SONiC FDB state ───

class Port:
    def __init__(self, alias, port_type="PHY"):
        self.m_alias = alias
        self.m_type = port_type
        self.m_bridge_port_id = None  # SAI_NULL_OBJECT_ID
        self.m_fdb_count = 0

class FdbEntry:
    """Key = (mac, bv_id)"""
    def __init__(self, mac, bv_id):
        self.mac = mac
        self.bv_id = bv_id
    def __eq__(self, other):
        return self.mac == other.mac and self.bv_id == other.bv_id
    def __hash__(self):
        return hash((self.mac, self.bv_id))

class FdbData:
    def __init__(self, bridge_port_id, port_name, origin="LEARN",
                 sai_fdb_type="DYNAMIC", is_flush_pending=False):
        self.bridge_port_id = bridge_port_id
        self.port_name = port_name
        self.origin = origin
        self.sai_fdb_type = sai_fdb_type
        self.is_flush_pending = is_flush_pending

class PortsOrch:
    """Models portsorch.cpp — bridge port lifecycle + saiOidToAlias map"""
    def __init__(self):
        self.m_portList = {}        # alias -> Port
        self.saiOidToAlias = {}     # bridge_port_oid -> alias

    def addPort(self, alias, port_type="PHY"):
        self.m_portList[alias] = Port(alias, port_type)

    def getPortByBridgePortId(self, bridge_port_id):
        """fdborch.cpp relies on this to resolve bridge_port_id -> Port.
           Returns (success, port)."""
        # portsorch.cpp getPortByBridgePortId:
        #   auto it = saiOidToAlias.find(bridge_port_id)
        #   if (it == saiOidToAlias.end()) return false
        if bridge_port_id not in self.saiOidToAlias:
            return False, None
        alias = self.saiOidToAlias[bridge_port_id]
        if alias not in self.m_portList:
            return False, None
        return True, self.m_portList[alias]

    def addBridgePort(self, alias, bridge_port_oid):
        """portsorch.cpp:7256-7308"""
        port = self.m_portList[alias]
        port.m_bridge_port_id = bridge_port_oid
        self.m_portList[alias] = port
        self.saiOidToAlias[bridge_port_oid] = alias
        return True

    def removeBridgePort(self, alias, fdb_orch):
        """portsorch.cpp:7310-7388 — THE BUGGY FUNCTION

        Line 7346: gFdbOrch->flushFDBEntries(port.m_bridge_port_id, SAI_NULL_OBJECT_ID)
        Line 7357: sai_bridge_api->remove_bridge_port(port.m_bridge_port_id)  [SAI call]
        Line 7368: saiOidToAlias.erase(port.m_bridge_port_id)  ← ERASES BEFORE FLUSH ARRIVES
        Line 7369: port.m_bridge_port_id = SAI_NULL_OBJECT_ID
        """
        port = self.m_portList[alias]
        if port.m_bridge_port_id is None:
            return True

        old_bp_id = port.m_bridge_port_id

        # Line 7346: async flush (fire-and-forget)
        fdb_orch.flushFDBEntries(old_bp_id, None)

        # Line 7357: SAI removes bridge port (simulated)
        # Line 7368-7369: erase OID from map IMMEDIATELY
        del self.saiOidToAlias[old_bp_id]
        port.m_bridge_port_id = None
        self.m_portList[alias] = port

        return True

class FdbOrch:
    """Models fdborch.cpp — FDB entry lifecycle + event handling"""
    def __init__(self, ports_orch):
        self.m_entries = {}     # FdbEntry -> FdbData (the software cache)
        self.m_portsOrch = ports_orch
        self.events_dropped = []  # Track dropped events for assertion

    def flushFDBEntries(self, bridge_port_oid, vlan_oid):
        """fdborch.cpp:1198-1255 — sends async SAI flush, sets is_flush_pending"""
        for entry, data in self.m_entries.items():
            if (bridge_port_oid is not None and
                    data.bridge_port_id == bridge_port_oid):
                data.is_flush_pending = True

    def update_LEARNED(self, mac, bv_id, bridge_port_id):
        """fdborch.cpp:297-346 — handles SAI_FDB_EVENT_LEARNED

        Line 315-316: if (bridge_port_id && !getPortByBridgePortId(bridge_port_id, update.port))
        Line 327-343: for non-FLUSHED events, log error and RETURN (drop the event)
        """
        # Line 315-316
        if bridge_port_id is not None:
            success, port = self.m_portsOrch.getPortByBridgePortId(bridge_port_id)
            if not success:
                # Line 327-343: "Failed to get port by bridge port ID" → RETURN
                self.events_dropped.append(("LEARNED", mac, bv_id, bridge_port_id))
                return "DROPPED"

        # Normal LEARNED handling (fdborch.cpp:356-413)
        entry = FdbEntry(mac, bv_id)
        self.m_entries[entry] = FdbData(bridge_port_id, port.m_alias)
        port.m_fdb_count += 1
        self.m_portsOrch.m_portList[port.m_alias] = port
        return "PROCESSED"

    def update_AGED(self, mac, bv_id, bridge_port_id):
        """fdborch.cpp:414-622 — handles SAI_FDB_EVENT_AGED
        Same bridge_port_id check as LEARNED.
        """
        if bridge_port_id is not None:
            success, port = self.m_portsOrch.getPortByBridgePortId(bridge_port_id)
            if not success:
                self.events_dropped.append(("AGED", mac, bv_id, bridge_port_id))
                return "DROPPED"
        return "PROCESSED"


# ─── Model of ASIC state (what hardware actually has) ───

class AsicState:
    """Models what the SAI/hardware actually contains.
    The ASIC learns/ages MACs independently of orchagent's software cache.
    """
    def __init__(self):
        self.entries = set()  # set of (mac, bv_id)

    def learn(self, mac, bv_id):
        self.entries.add((mac, bv_id))

    def age(self, mac, bv_id):
        self.entries.discard((mac, bv_id))


def check_invariant(fdb_orch, asic):
    """FdbAsicConsistency: asicEntries ⊆ DOMAIN mEntries

    Every entry in the ASIC must have a corresponding entry in m_entries.
    If ASIC has an entry that m_entries doesn't, orchagent has "lost" that entry.
    """
    m_entries_keys = set((e.mac, e.bv_id) for e in fdb_orch.m_entries)
    orphans = asic.entries - m_entries_keys
    return len(orphans) == 0, orphans


def main():
    print("=" * 70)
    print("Bug 1: Stale Bridge Port OID Silently Drops FDB Events")
    print("=" * 70)
    print()

    # ─── Setup ───
    ports_orch = PortsOrch()
    fdb_orch = FdbOrch(ports_orch)
    asic = AsicState()

    ports_orch.addPort("Ethernet0")
    ports_orch.addPort("Vlan100", "VLAN")

    BP_OID = 0x3a000000002c33
    VLAN_OID = 0x26000000000796
    MAC1 = "7c:fe:90:12:22:ec"

    print("Step 1: Add bridge port for Ethernet0 on Vlan100")
    ports_orch.addBridgePort("Ethernet0", BP_OID)
    print(f"  saiOidToAlias[{hex(BP_OID)}] = 'Ethernet0'")
    print()

    print("Step 2: ASIC learns MAC on Ethernet0 (LEARNED event)")
    asic.learn(MAC1, VLAN_OID)
    result = fdb_orch.update_LEARNED(MAC1, VLAN_OID, BP_OID)
    print(f"  ASIC entry: ({MAC1}, Vlan100)")
    print(f"  FdbOrch.update(LEARNED) result: {result}")
    print(f"  m_entries has {len(fdb_orch.m_entries)} entry(ies)")
    ok, orphans = check_invariant(fdb_orch, asic)
    print(f"  FdbAsicConsistency: {'PASS' if ok else 'FAIL'}")
    print()

    print("Step 3: Remove Ethernet0 from VLAN (removeBridgePort)")
    print("  This calls flushFDBEntries() (async), then IMMEDIATELY erases")
    print("  saiOidToAlias entry — before flush notification arrives.")
    ports_orch.removeBridgePort("Ethernet0", fdb_orch)
    print(f"  saiOidToAlias has bridge port? {BP_OID in ports_orch.saiOidToAlias}")
    print(f"  Ethernet0.m_bridge_port_id = {ports_orch.m_portList['Ethernet0'].m_bridge_port_id}")
    print()

    print("Step 4: ASIC learns another MAC on same (now-stale) bridge port")
    print("  (or: AGED event arrives for existing entry referencing stale BP)")
    MAC2 = "aa:bb:cc:dd:ee:ff"
    asic.learn(MAC2, VLAN_OID)
    result = fdb_orch.update_LEARNED(MAC2, VLAN_OID, BP_OID)
    print(f"  FdbOrch.update(LEARNED) result: {result}")
    print(f"  ASIC has entry ({MAC2}, Vlan100): TRUE")
    print(f"  m_entries has entry ({MAC2}, Vlan100): {FdbEntry(MAC2, VLAN_OID) in fdb_orch.m_entries}")
    print()

    # ─── Check invariant ───
    print("=" * 70)
    print("INVARIANT CHECK: FdbAsicConsistency")
    print("  asicEntries ⊆ DOMAIN mEntries")
    print()
    ok, orphans = check_invariant(fdb_orch, asic)
    print(f"  ASIC entries: {asic.entries}")
    m_keys = set((e.mac, e.bv_id) for e in fdb_orch.m_entries)
    print(f"  m_entries keys: {m_keys}")
    print(f"  Orphan ASIC entries (in HW but not in SW): {orphans}")
    print()

    if not ok:
        print("  >>> INVARIANT VIOLATED: FdbAsicConsistency <<<")
        print()
        print(f"  Dropped events: {fdb_orch.events_dropped}")
        print()
        print("  Root cause: removeBridgePort() (portsorch.cpp:7368)")
        print("    saiOidToAlias.erase(port.m_bridge_port_id)")
        print("  runs BEFORE flush notification arrives, so subsequent")
        print("  LEARNED/AGED events with the stale bridge_port_id are")
        print("  silently dropped by FdbOrch::update() (fdborch.cpp:327-343)")
        print()
        print("  Impact: ASIC and m_entries diverge permanently.")
        print("  Historical: sonic-buildimage#26531 — 75-min traffic blackhole")
        print()
        print("BUG REPRODUCED")
        return 0
    else:
        print("  Invariant holds — bug NOT reproduced")
        return 1


if __name__ == "__main__":
    sys.exit(main())
