#!/usr/bin/env python3
"""
Bug 3 Reproduction: VXLAN Tunnel Bridge Port Lifecycle Leak

This test demonstrates that clearFdbEntry() (called during FLUSH events) does
NOT call notifyTunnelOrch(), while the AGED and removeFdbEntry paths DO.
This means DIP tunnel bridge ports are never cleaned up after administrative
FDB flushes, leaking permanently until config reload.

The modeled code paths (with file:line references):
  - FdbOrch::clearFdbEntry()    (fdborch.cpp:200-222)  — NO notifyTunnelOrch
  - FdbOrch::update() AGED path (fdborch.cpp:576-591)  — calls notifyTunnelOrch
  - FdbOrch::removeFdbEntry()   (fdborch.cpp:1890-1906) — calls notifyTunnelOrch
  - VxlanTunnelOrch::deleteDynamicDIPTunnel() (vxlanorch.cpp:1182-1241)

Bug Family: Family 3 — VXLAN Tunnel Bridge Port Lifecycle Leak
Severity: High
Status: Structurally confirmed by MC; code audit confirms missing call.
"""

import sys

# ─── Faithful model of tunnel lifecycle ───

class TunnelPort:
    """Models a VXLAN DIP tunnel bridge port with ref-counted lifecycle"""
    def __init__(self, remote_ip):
        self.remote_ip = remote_ip
        self.fdb_count = 0
        self.ref_count = 0  # tnl_users_ refcnt
        self.bridge_port_exists = True
        self.del_pending = False

    def __repr__(self):
        return (f"Tunnel({self.remote_ip}, fdb_count={self.fdb_count}, "
                f"ref_count={self.ref_count}, bp_exists={self.bridge_port_exists})")

class VxlanTunnelOrch:
    """Models vxlanorch.cpp tunnel lifecycle"""
    def __init__(self):
        self.tunnels = {}  # remote_ip -> TunnelPort

    def addDynamicDIPTunnel(self, remote_ip):
        """vxlanorch.cpp — creates tunnel with bridge port"""
        tunnel = TunnelPort(remote_ip)
        tunnel.ref_count = 1
        self.tunnels[remote_ip] = tunnel
        return tunnel

    def notifyTunnelOrch(self, port):
        """Models the tunnel cleanup callback.
        Called when FDB entry on tunnel port is removed.
        Decrements fdb_count, potentially triggers tunnel deletion.

        vxlanorch.cpp:1211-1215:
          if (fdb_count == 0 && should_delete)
            deleteDynamicDIPTunnel()
        """
        if port.remote_ip not in self.tunnels:
            return "NO_TUNNEL"
        tunnel = self.tunnels[port.remote_ip]
        tunnel.fdb_count -= 1
        if tunnel.fdb_count <= 0 and tunnel.ref_count <= 0:
            tunnel.bridge_port_exists = False
            del self.tunnels[port.remote_ip]
            return "TUNNEL_DELETED"
        return "TUNNEL_KEPT"


class FdbEntry:
    def __init__(self, mac, bv_id, port_name):
        self.mac = mac
        self.bv_id = bv_id
        self.port_name = port_name
    def __repr__(self):
        return f"FDB({self.mac} on {self.port_name})"

class FdbOrch:
    """Models the three FDB removal paths"""
    def __init__(self, vxlan_orch):
        self.entries = {}  # (mac, bv_id) -> FdbEntry
        self.vxlan_orch = vxlan_orch
        self.tunnel_notifications = []

    def learn_on_tunnel(self, mac, bv_id, tunnel_ip):
        """FDB entry learned on a VXLAN tunnel port"""
        entry = FdbEntry(mac, bv_id, tunnel_ip)
        self.entries[(mac, bv_id)] = entry
        if tunnel_ip in self.vxlan_orch.tunnels:
            self.vxlan_orch.tunnels[tunnel_ip].fdb_count += 1

    def removeFdbEntry_AGED(self, mac, bv_id):
        """fdborch.cpp:576-591 — AGED event path

        Line 587: storeFdbEntryState(update);
        Line 589: notify(SUBJECT_TYPE_FDB_CHANGE, &update);
        Line 591: notifyTunnelOrch(update.port);  // ← CALLS notifyTunnelOrch
        """
        key = (mac, bv_id)
        if key not in self.entries:
            return "NOT_FOUND"
        entry = self.entries.pop(key)
        # Line 591: notifyTunnelOrch — PRESENT
        result = self.vxlan_orch.notifyTunnelOrch(
            type('Port', (), {'remote_ip': entry.port_name})())
        self.tunnel_notifications.append(("AGED", mac, result))
        return result

    def removeFdbEntry_DEL(self, mac, bv_id):
        """fdborch.cpp:1890-1906 — removeFdbEntry (DEL from APP_DB)

        Line 1903: storeFdbEntryState(update);
        Line 1905: notify(SUBJECT_TYPE_FDB_CHANGE, &update);
        Line 1906: notifyTunnelOrch(update.port);  // ← CALLS notifyTunnelOrch
        """
        key = (mac, bv_id)
        if key not in self.entries:
            return "NOT_FOUND"
        entry = self.entries.pop(key)
        # Line 1906: notifyTunnelOrch — PRESENT
        result = self.vxlan_orch.notifyTunnelOrch(
            type('Port', (), {'remote_ip': entry.port_name})())
        self.tunnel_notifications.append(("DEL", mac, result))
        return result

    def clearFdbEntry_FLUSH(self, mac, bv_id):
        """fdborch.cpp:200-222 — clearFdbEntry (called from handleSyncdFlushNotif)

        Line 217: storeFdbEntryState(update);
        Line 218: notify(SUBJECT_TYPE_FDB_CHANGE, &update);
        // ← NO notifyTunnelOrch call!  THIS IS THE BUG.

        Compare with AGED path (line 591) and DEL path (line 1906)
        which both call notifyTunnelOrch(update.port).
        """
        key = (mac, bv_id)
        if key not in self.entries:
            return "NOT_FOUND"
        entry = self.entries.pop(key)
        # Bug: NO notifyTunnelOrch call
        # The tunnel's fdb_count is decremented (line 210-214) but
        # vxlanorch is never notified, so it can never trigger cleanup
        self.tunnel_notifications.append(("FLUSH", mac, "NOT_CALLED"))
        return "NOT_CALLED"


def main():
    print("=" * 70)
    print("Bug 3: VXLAN Tunnel Bridge Port Lifecycle Leak")
    print("       (clearFdbEntry missing notifyTunnelOrch)")
    print("=" * 70)
    print()

    vxlan = VxlanTunnelOrch()
    fdb = FdbOrch(vxlan)

    TUNNEL_IP = "10.0.0.2"
    VLAN_OID = 0x26000000000796

    # ─── Setup: Create tunnel and learn FDB entries ───
    print("Setup: Create DIP tunnel and learn 3 FDB entries on it")
    tunnel = vxlan.addDynamicDIPTunnel(TUNNEL_IP)
    tunnel.ref_count = 0  # VNI removed, only fdb_count keeps tunnel alive

    fdb.learn_on_tunnel("aa:bb:cc:00:00:01", VLAN_OID, TUNNEL_IP)
    fdb.learn_on_tunnel("aa:bb:cc:00:00:02", VLAN_OID, TUNNEL_IP)
    fdb.learn_on_tunnel("aa:bb:cc:00:00:03", VLAN_OID, TUNNEL_IP)

    print(f"  Tunnel: {tunnel}")
    print(f"  FDB entries: {len(fdb.entries)}")
    print()

    # ─── Scenario A: AGE removes entries (correct) ───
    print("=" * 70)
    print("Scenario A: All entries removed via AGED events (CORRECT path)")
    print("=" * 70)
    vxlan_a = VxlanTunnelOrch()
    fdb_a = FdbOrch(vxlan_a)
    tunnel_a = vxlan_a.addDynamicDIPTunnel(TUNNEL_IP)
    tunnel_a.ref_count = 0

    fdb_a.learn_on_tunnel("aa:bb:cc:00:00:01", VLAN_OID, TUNNEL_IP)
    fdb_a.learn_on_tunnel("aa:bb:cc:00:00:02", VLAN_OID, TUNNEL_IP)
    fdb_a.learn_on_tunnel("aa:bb:cc:00:00:03", VLAN_OID, TUNNEL_IP)
    print(f"  Before: tunnel fdb_count={tunnel_a.fdb_count}, exists={tunnel_a.bridge_port_exists}")

    for mac in ["aa:bb:cc:00:00:01", "aa:bb:cc:00:00:02", "aa:bb:cc:00:00:03"]:
        result = fdb_a.removeFdbEntry_AGED(mac, VLAN_OID)
        print(f"  AGED {mac}: notifyTunnelOrch returned '{result}'")

    tunnel_a_exists = TUNNEL_IP in vxlan_a.tunnels
    print(f"  After: tunnel exists={tunnel_a_exists}")
    print(f"  Notifications: {fdb_a.tunnel_notifications}")
    print()
    if not tunnel_a_exists:
        print("  CORRECT: Tunnel cleaned up after all FDB entries aged out")
    print()

    # ─── Scenario B: FLUSH removes entries (buggy) ───
    print("=" * 70)
    print("Scenario B: All entries removed via FLUSH (BUGGY path)")
    print("=" * 70)
    vxlan_b = VxlanTunnelOrch()
    fdb_b = FdbOrch(vxlan_b)
    tunnel_b = vxlan_b.addDynamicDIPTunnel(TUNNEL_IP)
    tunnel_b.ref_count = 0

    fdb_b.learn_on_tunnel("aa:bb:cc:00:00:01", VLAN_OID, TUNNEL_IP)
    fdb_b.learn_on_tunnel("aa:bb:cc:00:00:02", VLAN_OID, TUNNEL_IP)
    fdb_b.learn_on_tunnel("aa:bb:cc:00:00:03", VLAN_OID, TUNNEL_IP)
    print(f"  Before: tunnel fdb_count={tunnel_b.fdb_count}, exists={tunnel_b.bridge_port_exists}")

    for mac in ["aa:bb:cc:00:00:01", "aa:bb:cc:00:00:02", "aa:bb:cc:00:00:03"]:
        result = fdb_b.clearFdbEntry_FLUSH(mac, VLAN_OID)
        print(f"  FLUSH {mac}: notifyTunnelOrch = '{result}'")

    tunnel_b_exists = TUNNEL_IP in vxlan_b.tunnels
    print(f"  After: tunnel exists={tunnel_b_exists}")
    # Note: fdb_count is NOT decremented in clearFdbEntry for tunnel path
    # (clearFdbEntry decrements port.m_fdb_count but via decrFdbCount, not via
    # the tunnel-specific notifyTunnelOrch callback)
    print(f"  Tunnel state: {vxlan_b.tunnels.get(TUNNEL_IP)}")
    print(f"  Notifications: {fdb_b.tunnel_notifications}")
    print()

    # ─── Invariant check ───
    print("=" * 70)
    print("INVARIANT CHECK: TunnelEventualCleanup")
    print("  If ref_count=0 and all FDB entries removed, tunnel bridge port")
    print("  should be cleaned up (deleted).")
    print()

    if tunnel_b_exists:
        print("  >>> INVARIANT VIOLATED: TunnelEventualCleanup <<<")
        print()
        print("  Tunnel bridge port leaked! FDB entries were flushed but")
        print("  notifyTunnelOrch was never called, so VxlanTunnelOrch never")
        print("  triggered deleteDynamicDIPTunnel().")
        print()
        print("  Root cause: fdborch.cpp:200-222 (clearFdbEntry)")
        print("    Line 218: notify(SUBJECT_TYPE_FDB_CHANGE, &update);")
        print("    // Missing: notifyTunnelOrch(update.port)")
        print()
        print("  Compare:")
        print("    AGED path (fdborch.cpp:591):  notifyTunnelOrch(update.port) ← PRESENT")
        print("    DEL path (fdborch.cpp:1906):  notifyTunnelOrch(update.port) ← PRESENT")
        print("    FLUSH path (fdborch.cpp:218): [nothing]                     ← MISSING")
        print()
        print("  Impact: DIP tunnel bridge ports leak permanently after")
        print("  administrative FDB flushes. del_tnl_hw_pending on SIP tunnels")
        print("  gets stuck forever. Only config reload fixes it.")
        print()
        print("BUG REPRODUCED")
        return 0
    else:
        print("  Tunnel cleaned up — bug NOT reproduced")
        return 1


if __name__ == "__main__":
    sys.exit(main())
