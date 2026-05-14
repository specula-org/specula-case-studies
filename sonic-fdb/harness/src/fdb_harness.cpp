/*
 * Standalone FDB Trace Harness for SONiC FDB Bridge Port Lifecycle
 *
 * This harness faithfully models the FDB state machine as implemented in
 * sonic-swss orchagent (fdborch.cpp, portsorch.cpp, vxlanorch.cpp).
 * Each function mirrors the real code's control flow and state updates.
 *
 * Trace emit points match the instrumentation spec exactly.
 *
 * Build: g++ -std=c++17 -O2 -o fdb_harness fdb_harness.cpp -I. -lgtest -lgtest_main -pthread
 * Run:   SONIC_FDB_TRACE_FILE=trace.ndjson ./fdb_harness
 */

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>
#include <map>
#include <set>
#include <string>
#include <tuple>
#include <vector>
#include <cstdint>
#include <cassert>
#include <chrono>
#include <cstdio>

using json = nlohmann::json;
using std::string;
using std::map;
using std::set;

// --- Direct trace writer (bypasses tla_trace.h singleton) ---
static FILE* g_trace_fp = nullptr;
static string g_trace_dir;

static void openTrace(const string& name) {
    if (g_trace_fp) { fclose(g_trace_fp); g_trace_fp = nullptr; }
    string path = g_trace_dir + "/" + name + ".ndjson";
    g_trace_fp = fopen(path.c_str(), "w");
    assert(g_trace_fp);
}

static void emitTrace(const json& event) {
    if (!g_trace_fp) return;
    json line = event;
    line["tag"] = "trace";
    auto now = std::chrono::steady_clock::now();
    auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        now.time_since_epoch()).count();
    line["ts"] = ns;
    fprintf(g_trace_fp, "%s\n", line.dump().c_str());
    fflush(g_trace_fp);
}

static void closeTrace() {
    if (g_trace_fp) { fclose(g_trace_fp); g_trace_fp = nullptr; }
}

// Override the macro BEFORE function definitions
#define SONIC_TLA_TRACE_EMIT(event_json) emitTrace(event_json)

// --- Types matching orchagent ---

enum FdbOrigin {
    FDB_ORIGIN_INVALID = 0,
    FDB_ORIGIN_LEARN = 1,
    FDB_ORIGIN_PROVISIONED = 2,
    FDB_ORIGIN_VXLAN_ADVERTIZED = 4,
    FDB_ORIGIN_MCLAG_ADVERTIZED = 8
};

static string originToString(FdbOrigin o) {
    switch (o) {
        case FDB_ORIGIN_LEARN: return "learn";
        case FDB_ORIGIN_PROVISIONED: return "provisioned";
        case FDB_ORIGIN_VXLAN_ADVERTIZED: return "vxlan_advertized";
        case FDB_ORIGIN_MCLAG_ADVERTIZED: return "mclag_advertized";
        default: return "invalid";
    }
}

struct FdbKey {
    string mac;
    string vlan;
    bool operator<(const FdbKey& o) const {
        return std::tie(mac, vlan) < std::tie(o.mac, o.vlan);
    }
    bool operator==(const FdbKey& o) const {
        return mac == o.mac && vlan == o.vlan;
    }
};

struct FdbData {
    FdbOrigin origin;
    string type;  // "dynamic" or "static"
    string port;  // port alias or vtep IP
    bool is_flush_pending;
};

// --- Orchestrator State ---
// Models the state from base.tla Init

struct OrchaState {
    // Bridge port state (portsorch.cpp)
    map<string, bool> bridgePortExists;    // port -> bool
    set<string> saiOidToAlias;             // ports whose OID is in lookup map
    map<string, set<string>> vlanMembers;  // vlan -> set of ports

    // FDB entry state (fdborch.cpp)
    map<FdbKey, FdbData> mEntries;

    // Async flush state
    set<string> pendingFlushPort;
    set<string> pendingFlushVlan;

    // VXLAN tunnel state (vxlanorch.cpp)
    map<string, bool> tunnelExists;
    map<string, int> tunnelRefCnt;
    map<string, int> tunnelFdbCount;

    // FDB counters
    map<string, int> portFdbCount;
    map<string, int> vlanFdbCount;

    void init(const std::vector<string>& ports,
              const std::vector<string>& vlans,
              const std::vector<string>& vteps) {
        for (auto& p : ports) {
            bridgePortExists[p] = false;
            portFdbCount[p] = 0;
        }
        for (auto& v : vlans) {
            vlanMembers[v] = {};
            vlanFdbCount[v] = 0;
        }
        for (auto& vtep : vteps) {
            tunnelExists[vtep] = false;
            tunnelRefCnt[vtep] = 0;
            tunnelFdbCount[vtep] = 0;
        }
    }

    bool canResolveBridgePort(const string& p) const {
        auto it = bridgePortExists.find(p);
        return it != bridgePortExists.end() && it->second &&
               saiOidToAlias.count(p) > 0;
    }

    bool isPortInAnyVlan(const string& p) const {
        for (auto& [v, members] : vlanMembers) {
            if (members.count(p)) return true;
        }
        return false;
    }
};

// --- Actions (matching spec) ---
// Each function modifies state and emits trace events

// 1. AddVlanMember (portsorch.cpp:doVlanMemberTask SET path)
static void addVlanMember(OrchaState& s, const string& port, const string& vlan) {
    if (s.vlanMembers[vlan].count(port)) return; // duplicate

    bool wasNew = !s.bridgePortExists[port];
    // addBridgePort (portsorch.cpp:7186-7281)
    if (wasNew) {
        s.bridgePortExists[port] = true;
        s.saiOidToAlias.insert(port);
    }
    // addVlanMember
    s.vlanMembers[vlan].insert(port);

    // Trace emit: after successful addBridgePort/addVlanMember
    SONIC_TLA_TRACE_EMIT(json({
        {"event", "add_vlan_member"},
        {"port", port},
        {"vlan", vlan},
        {"bridge_port_exists", s.bridgePortExists[port]},
        {"in_oid_map", s.saiOidToAlias.count(port) > 0}
    }));
}

// 2. RemoveVlanMember (portsorch.cpp:doVlanMemberTask DEL path)
static void removeVlanMember(OrchaState& s, const string& port, const string& vlan) {
    if (!s.vlanMembers[vlan].count(port)) return;

    // removeVlanMember
    s.vlanMembers[vlan].erase(port);

    // Trace emit: after removeVlanMember, BEFORE removeBridgePort
    SONIC_TLA_TRACE_EMIT(json({
        {"event", "remove_vlan_member"},
        {"port", port},
        {"vlan", vlan},
        {"bridge_port_exists", s.bridgePortExists[port]},
        {"in_oid_map", s.saiOidToAlias.count(port) > 0}
    }));
}

// 3. FlushFDBForRemove (portsorch.cpp:removeBridgePort line 7318-7320)
static void flushFDBForRemove(OrchaState& s, const string& port) {
    if (!s.bridgePortExists[port]) return;
    if (s.isPortInAnyVlan(port)) return;

    // flushFDBEntries sets is_flush_pending on matching entries (fdborch.cpp:1135-1146)
    for (auto& [k, d] : s.mEntries) {
        if (d.port == port && d.type == "dynamic") {
            d.is_flush_pending = true;
        }
    }
    s.pendingFlushPort.insert(port);

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "flush_fdb_for_remove"},
        {"port", port}
    }));
}

// 4. RemoveBridgePortHW (portsorch.cpp:removeBridgePort lines 7322-7343)
static void removeBridgePortHW(OrchaState& s, const string& port) {
    if (!s.bridgePortExists[port]) return;
    if (s.isPortInAnyVlan(port)) return;
    if (!s.pendingFlushPort.count(port)) return;

    // SAI remove bridge port (line 7322-7333)
    s.bridgePortExists[port] = false;
    // Erase from OID map BEFORE flush notification (line 7334) — FAMILY 1 ROOT CAUSE
    s.saiOidToAlias.erase(port);

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "remove_bridge_port_hw"},
        {"port", port},
        {"bridge_port_exists", false},
        {"in_oid_map", false}
    }));
}

// 5. HandleFlushNotification (fdborch.cpp:handleSyncdFlushNotif)
static void handleFlushNotification(OrchaState& s, const string& port) {
    if (!s.pendingFlushPort.count(port)) return;
    s.pendingFlushPort.erase(port);

    // handleSyncdFlushNotif iterates m_entries
    // Only clears entries where is_flush_pending == TRUE
    std::vector<FdbKey> toClear;
    for (auto& [k, d] : s.mEntries) {
        if (d.port == port && d.type == "dynamic" && d.is_flush_pending) {
            toClear.push_back(k);
        }
    }
    for (auto& k : toClear) {
        auto& d = s.mEntries[k];
        // clearFdbEntry (fdborch.cpp:181-203)
        s.portFdbCount[d.port]--;
        s.vlanFdbCount[k.vlan]--;
        s.mEntries.erase(k);
    }

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "handle_flush_notification"},
        {"port", port},
        {"port_fdb_count", s.portFdbCount[port]}
    }));
}

// 6. HandleFlushNotificationVlan (fdborch.cpp:handleSyncdFlushNotif VLAN-scoped)
static void handleFlushNotificationVlan(OrchaState& s, const string& vlan) {
    if (!s.pendingFlushVlan.count(vlan)) return;
    s.pendingFlushVlan.erase(vlan);

    // Family 2: flushFdbByVlan does NOT set is_flush_pending
    // So handleSyncdFlushNotif checks is_flush_pending and skips ALL entries
    std::vector<FdbKey> toClear;
    for (auto& [k, d] : s.mEntries) {
        if (k.vlan == vlan && d.type == "dynamic" && d.is_flush_pending) {
            toClear.push_back(k);
        }
    }
    for (auto& k : toClear) {
        auto& d = s.mEntries[k];
        s.portFdbCount[d.port]--;
        s.vlanFdbCount[k.vlan]--;
        s.mEntries.erase(k);
    }

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "handle_flush_notification_vlan"},
        {"vlan", vlan},
        {"vlan_fdb_count", s.vlanFdbCount[vlan]}
    }));
}

// 7. FlushFdbByVlan (fdborch.cpp:1149-1177)
static void flushFdbByVlan(OrchaState& s, const string& vlan) {
    s.pendingFlushVlan.insert(vlan);
    // Family 2 BUG: does NOT set is_flush_pending

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "flush_fdb_by_vlan"},
        {"vlan", vlan}
    }));
}

// 8. LearnFdbEntry (fdborch.cpp:update LEARNED handler, new entry path)
static void learnFdbEntry(OrchaState& s, const string& mac, const string& vlan,
                           const string& port) {
    FdbKey key{mac, vlan};
    if (s.mEntries.count(key)) return;  // already exists
    if (!s.canResolveBridgePort(port)) return;

    s.mEntries[key] = FdbData{FDB_ORIGIN_LEARN, "dynamic", port, false};
    s.portFdbCount[port]++;
    s.vlanFdbCount[vlan]++;

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "learn_fdb_entry"},
        {"mac", mac},
        {"vlan", vlan},
        {"port", port},
        {"entry_exists", true},
        {"entry_origin", "learn"},
        {"entry_port", port},
        {"port_fdb_count", s.portFdbCount[port]},
        {"vlan_fdb_count", s.vlanFdbCount[vlan]}
    }));
}

// 9. LearnFdbEntryDropped (fdborch.cpp:296-312, bridge port not in OID map)
static void learnFdbEntryDropped(OrchaState& s, const string& mac, const string& vlan,
                                  const string& port) {
    // Bridge port OID not in map — FAMILY 1 indicator
    if (s.canResolveBridgePort(port)) return;  // would NOT be dropped

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "learn_fdb_entry_dropped"},
        {"mac", mac},
        {"vlan", vlan},
        {"port", port}
    }));
}

// 10. AgeFdbEntry (fdborch.cpp:update AGED handler, dynamic non-MCLAG)
static void ageFdbEntry(OrchaState& s, const string& mac, const string& vlan) {
    FdbKey key{mac, vlan};
    auto it = s.mEntries.find(key);
    if (it == s.mEntries.end()) return;
    auto& d = it->second;
    if (d.type != "dynamic" || d.origin != FDB_ORIGIN_LEARN) return;
    // Must be physical port (tunnel ages handled separately)
    if (s.tunnelExists.count(d.port)) return;

    string port = d.port;
    s.portFdbCount[port]--;
    s.vlanFdbCount[vlan]--;
    s.mEntries.erase(key);

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "age_fdb_entry"},
        {"mac", mac},
        {"vlan", vlan},
        {"port", port},
        {"entry_exists", false},
        {"port_fdb_count", s.portFdbCount[port]},
        {"vlan_fdb_count", s.vlanFdbCount[vlan]}
    }));
}

// 11. AgeFdbEntryDropped (fdborch.cpp:296-312, AGED event dropped)
static void ageFdbEntryDropped(OrchaState& s, const string& mac, const string& vlan) {
    FdbKey key{mac, vlan};
    auto it = s.mEntries.find(key);
    if (it == s.mEntries.end()) return;
    auto& d = it->second;
    if (s.canResolveBridgePort(d.port)) return;  // would NOT be dropped

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "age_fdb_entry_dropped"},
        {"mac", mac},
        {"vlan", vlan}
    }));
}

// 12. MoveFdbEntry (fdborch.cpp:update MOVE handler)
static void moveFdbEntry(OrchaState& s, const string& mac, const string& vlan,
                          const string& newPort) {
    FdbKey key{mac, vlan};
    auto it = s.mEntries.find(key);
    if (it == s.mEntries.end()) return;
    if (!s.canResolveBridgePort(newPort)) return;

    string oldPort = it->second.port;
    if (newPort == oldPort) return;
    if (!s.canResolveBridgePort(oldPort)) return;

    // Update port
    it->second.port = newPort;
    // Counter bookkeeping (fdborch.cpp:607-617)
    s.portFdbCount[oldPort]--;
    s.portFdbCount[newPort]++;
    // Family 5 BUG: MOVE does NOT update vlan.m_fdb_count

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "move_fdb_entry"},
        {"mac", mac},
        {"vlan", vlan},
        {"port", newPort},
        {"new_port", newPort},
        {"entry_exists", true},
        {"entry_port", newPort},
        {"port_fdb_count", s.portFdbCount[newPort]},
        {"vlan_fdb_count", s.vlanFdbCount[vlan]}
    }));
}

// 13. AddFdbEntryProvisioned (fdborch.cpp:addFdbEntry with ORIGIN_PROVISIONED)
static void addFdbEntryProvisioned(OrchaState& s, const string& mac, const string& vlan,
                                    const string& port) {
    if (!s.canResolveBridgePort(port)) return;
    FdbKey key{mac, vlan};

    auto it = s.mEntries.find(key);
    if (it != s.mEntries.end()) {
        auto& old = it->second;
        if (old.origin == FDB_ORIGIN_PROVISIONED && old.port == port) return; // dup
        // Provisioned always wins (highest priority)
        if (old.port != port && s.portFdbCount.count(old.port)) {
            s.portFdbCount[old.port]--;
            s.portFdbCount[port]++;
        }
        old.origin = FDB_ORIGIN_PROVISIONED;
        old.type = "static";
        old.port = port;
        old.is_flush_pending = false;
    } else {
        s.mEntries[key] = FdbData{FDB_ORIGIN_PROVISIONED, "static", port, false};
        s.portFdbCount[port]++;
        s.vlanFdbCount[vlan]++;
    }

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "add_fdb_entry_provisioned"},
        {"mac", mac},
        {"vlan", vlan},
        {"port", port},
        {"entry_exists", true},
        {"entry_origin", "provisioned"},
        {"port_fdb_count", s.portFdbCount[port]},
        {"vlan_fdb_count", s.vlanFdbCount[vlan]}
    }));
}

// 14. RemoveFdbEntry (fdborch.cpp:removeFdbEntry)
static void removeFdbEntry(OrchaState& s, const string& mac, const string& vlan,
                            FdbOrigin origin) {
    FdbKey key{mac, vlan};
    auto it = s.mEntries.find(key);
    if (it == s.mEntries.end()) return;

    auto& d = it->second;
    if (d.origin != origin) {
        // Family 4 BUG: origin mismatch — return true without deletion
        SONIC_TLA_TRACE_EMIT(json({
            {"event", "remove_fdb_entry"},
            {"mac", mac},
            {"vlan", vlan},
            {"port", d.port},
            {"origin", originToString(origin)},
            {"entry_exists", true},
            {"port_fdb_count", s.portFdbCount.count(d.port) ? s.portFdbCount[d.port] : 0},
            {"vlan_fdb_count", s.vlanFdbCount[vlan]}
        }));
        return;
    }

    // Origins match — delete
    string port = d.port;
    bool isPhysical = s.portFdbCount.count(port) > 0;
    if (isPhysical) s.portFdbCount[port]--;
    s.vlanFdbCount[vlan]--;
    s.mEntries.erase(key);

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "remove_fdb_entry"},
        {"mac", mac},
        {"vlan", vlan},
        {"port", port},
        {"origin", originToString(origin)},
        {"entry_exists", false},
        {"port_fdb_count", isPhysical ? s.portFdbCount[port] : 0},
        {"vlan_fdb_count", s.vlanFdbCount[vlan]}
    }));
}

// 15. LearnFdbOnTunnel (fdborch.cpp:addFdbEntry with ORIGIN_VXLAN_ADVERTIZED)
static void learnFdbOnTunnel(OrchaState& s, const string& mac, const string& vlan,
                              const string& vtep) {
    if (!s.tunnelExists[vtep]) return;
    FdbKey key{mac, vlan};
    if (s.mEntries.count(key)) return;

    s.mEntries[key] = FdbData{FDB_ORIGIN_VXLAN_ADVERTIZED, "dynamic", vtep, false};
    s.tunnelFdbCount[vtep]++;
    s.vlanFdbCount[vlan]++;

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "learn_fdb_on_tunnel"},
        {"mac", mac},
        {"vlan", vlan},
        {"vtep", vtep},
        {"entry_exists", true},
        {"tunnel_fdb_count", s.tunnelFdbCount[vtep]},
        {"tunnel_ref_cnt", s.tunnelRefCnt[vtep]}
    }));
}

// 16. AgeFdbOnTunnel (fdborch.cpp:update AGED handler for tunnel entries)
static void ageFdbOnTunnel(OrchaState& s, const string& mac, const string& vlan) {
    FdbKey key{mac, vlan};
    auto it = s.mEntries.find(key);
    if (it == s.mEntries.end()) return;
    auto& d = it->second;
    if (!s.tunnelExists.count(d.port)) return;  // must be tunnel entry
    if (d.type != "dynamic") return;

    string vtep = d.port;
    s.tunnelFdbCount[vtep]--;
    s.vlanFdbCount[vlan]--;
    s.mEntries.erase(key);

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "age_fdb_on_tunnel"},
        {"mac", mac},
        {"vlan", vlan},
        {"entry_exists", false},
        {"tunnel_fdb_count", s.tunnelFdbCount[vtep]},
        {"tunnel_exists", s.tunnelExists[vtep]}
    }));
}

// 17. FlushFdbOnTunnel (fdborch.cpp:clearFdbEntry for tunnel entries)
static void flushFdbOnTunnel(OrchaState& s, const string& mac, const string& vlan) {
    FdbKey key{mac, vlan};
    auto it = s.mEntries.find(key);
    if (it == s.mEntries.end()) return;
    auto& d = it->second;
    if (!s.tunnelExists.count(d.port)) return;
    if (!d.is_flush_pending) return;

    // Family 3 BUG: clearFdbEntry does NOT call notifyTunnelOrch
    // tunnelFdbCount is NOT decremented
    s.vlanFdbCount[vlan]--;
    s.mEntries.erase(key);

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "flush_fdb_on_tunnel"},
        {"mac", mac},
        {"vlan", vlan},
        {"entry_exists", false}
    }));
}

// 18. AddRemoteVNI (vxlanorch.cpp:EvpnRemoteVnip2pOrch::addOperation)
static void addRemoteVNI(OrchaState& s, const string& vtep) {
    if (s.tunnelExists[vtep]) {
        s.tunnelRefCnt[vtep]++;
    } else {
        s.tunnelExists[vtep] = true;
        s.tunnelRefCnt[vtep] = 1;
    }

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "add_remote_vni"},
        {"vtep", vtep},
        {"tunnel_exists", true},
        {"tunnel_ref_cnt", s.tunnelRefCnt[vtep]}
    }));
}

// 19. DelRemoteVNI (vxlanorch.cpp:deleteDynamicDIPTunnel)
static void delRemoteVNI(OrchaState& s, const string& vtep) {
    if (!s.tunnelExists[vtep]) return;
    if (s.tunnelRefCnt[vtep] <= 0) return;

    s.tunnelRefCnt[vtep]--;
    if (s.tunnelRefCnt[vtep] == 0 && s.tunnelFdbCount[vtep] == 0) {
        s.tunnelExists[vtep] = false;
    }

    SONIC_TLA_TRACE_EMIT(json({
        {"event", "del_remote_vni"},
        {"vtep", vtep},
        {"tunnel_exists", s.tunnelExists[vtep]},
        {"tunnel_ref_cnt", s.tunnelRefCnt[vtep]}
    }));
}

// ===== Test Scenarios =====

// Scenario 1: Basic FDB lifecycle
// AddVlanMember -> LearnFdbEntry -> AgeFdbEntry -> RemoveVlanMember
TEST(FdbTrace, BasicLifecycle) {
    openTrace("basic_lifecycle");
    OrchaState s;
    s.init({"Ethernet0", "Ethernet4"}, {"Vlan1000"}, {"10.0.0.1"});

    // Setup: Add Ethernet0 to Vlan1000
    addVlanMember(s, "Ethernet0", "Vlan1000");
    EXPECT_TRUE(s.bridgePortExists["Ethernet0"]);
    EXPECT_TRUE(s.saiOidToAlias.count("Ethernet0"));

    // Learn a MAC on Ethernet0
    learnFdbEntry(s, "00:11:22:33:44:55", "Vlan1000", "Ethernet0");
    EXPECT_EQ(s.portFdbCount["Ethernet0"], 1);
    EXPECT_EQ(s.vlanFdbCount["Vlan1000"], 1);

    // Learn a second MAC
    learnFdbEntry(s, "00:11:22:33:44:66", "Vlan1000", "Ethernet0");
    EXPECT_EQ(s.portFdbCount["Ethernet0"], 2);
    EXPECT_EQ(s.vlanFdbCount["Vlan1000"], 2);

    // Age the first MAC
    ageFdbEntry(s, "00:11:22:33:44:55", "Vlan1000");
    EXPECT_EQ(s.portFdbCount["Ethernet0"], 1);

    // Age the second MAC
    ageFdbEntry(s, "00:11:22:33:44:66", "Vlan1000");
    EXPECT_EQ(s.portFdbCount["Ethernet0"], 0);

    // Remove VLAN member
    removeVlanMember(s, "Ethernet0", "Vlan1000");
    EXPECT_TRUE(s.bridgePortExists["Ethernet0"]); // still exists until removeBridgePort

    // Flush and remove bridge port
    flushFDBForRemove(s, "Ethernet0");
    removeBridgePortHW(s, "Ethernet0");
    EXPECT_FALSE(s.bridgePortExists["Ethernet0"]);

    // Flush notification arrives
    handleFlushNotification(s, "Ethernet0");

    closeTrace();
}

// Scenario 2: MAC move and provisioned entry
TEST(FdbTrace, MoveAndProvision) {
    openTrace("move_and_provision");
    OrchaState s;
    s.init({"Ethernet0", "Ethernet4"}, {"Vlan1000"}, {"10.0.0.1"});

    // Setup: Add both ports to VLAN
    addVlanMember(s, "Ethernet0", "Vlan1000");
    addVlanMember(s, "Ethernet4", "Vlan1000");

    // Learn MAC on Ethernet0
    learnFdbEntry(s, "00:11:22:33:44:55", "Vlan1000", "Ethernet0");
    EXPECT_EQ(s.portFdbCount["Ethernet0"], 1);

    // Move MAC to Ethernet4
    moveFdbEntry(s, "00:11:22:33:44:55", "Vlan1000", "Ethernet4");
    EXPECT_EQ(s.portFdbCount["Ethernet0"], 0);
    EXPECT_EQ(s.portFdbCount["Ethernet4"], 1);

    // Provision a static MAC on Ethernet0
    addFdbEntryProvisioned(s, "00:11:22:33:44:66", "Vlan1000", "Ethernet0");
    EXPECT_EQ(s.portFdbCount["Ethernet0"], 1);

    // Remove the provisioned entry
    removeFdbEntry(s, "00:11:22:33:44:66", "Vlan1000", FDB_ORIGIN_PROVISIONED);
    EXPECT_EQ(s.portFdbCount["Ethernet0"], 0);

    // Age the moved entry
    ageFdbEntry(s, "00:11:22:33:44:55", "Vlan1000");

    closeTrace();
}

// Scenario 3: Bridge port race (Family 1)
// Shows learn event dropped after bridge port removal
TEST(FdbTrace, BridgePortRace) {
    openTrace("bridge_port_race");
    OrchaState s;
    s.init({"Ethernet0", "Ethernet4"}, {"Vlan1000"}, {"10.0.0.1"});

    // Setup
    addVlanMember(s, "Ethernet0", "Vlan1000");

    // Learn a MAC
    learnFdbEntry(s, "00:11:22:33:44:55", "Vlan1000", "Ethernet0");

    // Remove VLAN member -> triggers bridge port removal sequence
    removeVlanMember(s, "Ethernet0", "Vlan1000");
    flushFDBForRemove(s, "Ethernet0");
    removeBridgePortHW(s, "Ethernet0");
    // Bridge port OID now removed from saiOidToAlias

    // New LEARN event arrives for different MAC on same port
    // This will be DROPPED because bridge port OID not in map (Family 1)
    learnFdbEntryDropped(s, "00:11:22:33:44:66", "Vlan1000", "Ethernet0");

    // Flush notification finally arrives
    handleFlushNotification(s, "Ethernet0");

    closeTrace();
}

// Scenario 4: VXLAN tunnel lifecycle
TEST(FdbTrace, TunnelLifecycle) {
    openTrace("tunnel_lifecycle");
    OrchaState s;
    s.init({"Ethernet0", "Ethernet4"}, {"Vlan1000"}, {"10.0.0.1"});

    // Setup local port
    addVlanMember(s, "Ethernet0", "Vlan1000");

    // Add remote VNI -> creates tunnel
    addRemoteVNI(s, "10.0.0.1");
    EXPECT_TRUE(s.tunnelExists["10.0.0.1"]);
    EXPECT_EQ(s.tunnelRefCnt["10.0.0.1"], 1);

    // Learn remote MAC on tunnel
    learnFdbOnTunnel(s, "00:11:22:33:44:55", "Vlan1000", "10.0.0.1");
    EXPECT_EQ(s.tunnelFdbCount["10.0.0.1"], 1);

    // Learn local MAC
    learnFdbEntry(s, "00:11:22:33:44:66", "Vlan1000", "Ethernet0");

    // Age remote MAC (correctly decrements tunnel fdb_count via notifyTunnelOrch)
    ageFdbOnTunnel(s, "00:11:22:33:44:55", "Vlan1000");
    EXPECT_EQ(s.tunnelFdbCount["10.0.0.1"], 0);

    // Delete remote VNI -> removes tunnel (refcnt=0, fdb_count=0)
    delRemoteVNI(s, "10.0.0.1");
    EXPECT_FALSE(s.tunnelExists["10.0.0.1"]);

    // Age local MAC
    ageFdbEntry(s, "00:11:22:33:44:66", "Vlan1000");

    closeTrace();
}

// Scenario 5: VLAN flush and age dropped (covers missing event types)
TEST(FdbTrace, VlanFlushAndAgeDrop) {
    openTrace("vlan_flush_and_age_drop");
    OrchaState s;
    s.init({"Ethernet0", "Ethernet4"}, {"Vlan1000"}, {"10.0.0.1"});

    // Setup
    addVlanMember(s, "Ethernet0", "Vlan1000");

    // Learn MACs
    learnFdbEntry(s, "00:11:22:33:44:55", "Vlan1000", "Ethernet0");
    learnFdbEntry(s, "00:11:22:33:44:66", "Vlan1000", "Ethernet0");

    // Flush by VLAN (Family 2: does NOT set is_flush_pending)
    flushFdbByVlan(s, "Vlan1000");

    // VLAN-scoped flush notification arrives
    // Family 2: will skip entries because is_flush_pending was never set
    handleFlushNotificationVlan(s, "Vlan1000");

    // Now remove VLAN member and bridge port
    removeVlanMember(s, "Ethernet0", "Vlan1000");
    flushFDBForRemove(s, "Ethernet0");
    removeBridgePortHW(s, "Ethernet0");

    // AGED event arrives for MAC that still exists in m_entries
    // but bridge port is already removed -> dropped (Family 1)
    ageFdbEntryDropped(s, "00:11:22:33:44:55", "Vlan1000");

    // Flush notification for port
    handleFlushNotification(s, "Ethernet0");

    closeTrace();
}

// Note: flush_fdb_on_tunnel requires internal state manipulation (setting
// is_flush_pending manually) that cannot be captured via external trace events.
// This event type is covered by model checking (Family 3 bug) rather than
// trace validation. The 5 other scenarios cover 18/19 event types.

int main(int argc, char **argv) {
    // Determine trace output directory
    const char* dir = std::getenv("TRACE_OUTPUT_DIR");
    g_trace_dir = dir ? dir : ".";

    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
