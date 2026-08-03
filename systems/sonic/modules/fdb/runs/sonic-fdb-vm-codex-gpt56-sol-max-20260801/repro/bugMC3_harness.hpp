#pragma once

#include <algorithm>
#include <arpa/inet.h>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <typeindex>
#include <unordered_map>
#include <utility>
#include <vector>

using namespace std;

#define SWSS_LOG_ENTER() do { } while (0)
#define SWSS_LOG_ERROR(...) do { } while (0)
#define SWSS_LOG_WARN(...) do { } while (0)
#define SWSS_LOG_INFO(...) do { } while (0)
#define SWSS_LOG_NOTICE(...) do { } while (0)
#define SWSS_LOG_DEBUG(...) do { } while (0)

using sai_object_id_t = uint64_t;
using sai_status_t = int32_t;

constexpr sai_object_id_t SAI_NULL_OBJECT_ID = 0;
constexpr sai_status_t SAI_STATUS_SUCCESS = 0;
constexpr int SAI_NEXT_HOP_GROUP_ATTR_TYPE = 1;
constexpr int SAI_NEXT_HOP_GROUP_TYPE_BRIDGE_PORT = 2;
constexpr int SAI_NEXT_HOP_ATTR_TYPE = 3;
constexpr int SAI_NEXT_HOP_TYPE_BRIDGE_PORT = 4;
constexpr int SAI_NEXT_HOP_ATTR_IP = 5;
constexpr int SAI_NEXT_HOP_ATTR_TUNNEL_ID = 6;
constexpr int SAI_NEXT_HOP_GROUP_MEMBER_ATTR_NEXT_HOP_GROUP_ID = 7;
constexpr int SAI_NEXT_HOP_GROUP_MEMBER_ATTR_NEXT_HOP_ID = 8;
constexpr int SAI_API_NEXT_HOP_GROUP = 9;
constexpr int SAI_API_NEXT_HOP = 10;

struct sai_ip_address_t
{
    char text[INET6_ADDRSTRLEN]{};
};

struct sai_attribute_value_t
{
    int32_t s32{};
    sai_object_id_t oid{};
    sai_ip_address_t ipaddr{};
};

struct sai_attribute_t
{
    int id{};
    sai_attribute_value_t value{};
};

struct sai_next_hop_group_api_t
{
    sai_status_t (*create_next_hop_group)(sai_object_id_t *, sai_object_id_t, uint32_t, const sai_attribute_t *);
    sai_status_t (*remove_next_hop_group)(sai_object_id_t);
    sai_status_t (*create_next_hop_group_member)(sai_object_id_t *, sai_object_id_t, uint32_t, const sai_attribute_t *);
    sai_status_t (*remove_next_hop_group_member)(sai_object_id_t);
};

struct sai_next_hop_api_t
{
    sai_status_t (*create_next_hop)(sai_object_id_t *, sai_object_id_t, uint32_t, const sai_attribute_t *);
    sai_status_t (*remove_next_hop)(sai_object_id_t);
};

namespace swss
{
class IpAddress
{
  public:
    explicit IpAddress(const string &text) : text_(text)
    {
        in_addr v4{};
        in6_addr v6{};
        if (inet_pton(AF_INET, text.c_str(), &v4) != 1 &&
            inet_pton(AF_INET6, text.c_str(), &v6) != 1)
        {
            throw invalid_argument("invalid IP address");
        }
    }

    string to_string() const
    {
        return text_;
    }

  private:
    string text_;
};

inline void copy(sai_ip_address_t &out, const IpAddress &ip)
{
    snprintf(out.text, sizeof(out.text), "%s", ip.to_string().c_str());
}
} // namespace swss

using swss::IpAddress;

inline vector<string> tokenize(const string &input, char delimiter)
{
    vector<string> values;
    size_t start = 0;
    while (true)
    {
        const size_t end = input.find(delimiter, start);
        values.push_back(input.substr(start, end == string::npos ? end : end - start));
        if (end == string::npos)
        {
            return values;
        }
        start = end + 1;
    }
}

using FieldValueTuple = pair<string, string>;

struct KeyOpFieldsValuesTuple
{
    string key;
    string op;
    vector<FieldValueTuple> fields;
};

inline const string &kfvKey(const KeyOpFieldsValuesTuple &tuple) { return tuple.key; }
inline const string &kfvOp(const KeyOpFieldsValuesTuple &tuple) { return tuple.op; }
inline const vector<FieldValueTuple> &kfvFieldsValues(const KeyOpFieldsValuesTuple &tuple) { return tuple.fields; }
inline const string &fvField(const FieldValueTuple &tuple) { return tuple.first; }
inline const string &fvValue(const FieldValueTuple &tuple) { return tuple.second; }

inline const string SET_COMMAND = "SET";
inline const string DEL_COMMAND = "DEL";
inline const string APP_L2_NEXTHOP_GROUP_TABLE_NAME = "L2_NEXTHOP_GROUP_TABLE";

class DBConnector
{
};

class Table
{
  public:
    Table(DBConnector *, const string &name) : name_(name) {}
    string getTableNameSeparator() const { return ":"; }

  private:
    string name_;
};

class Consumer
{
  public:
    explicit Consumer(const string &name) : name_(name), table_(nullptr, name) {}

    string getTableName() const { return name_; }
    Table *getConsumerTable() { return &table_; }

    map<string, KeyOpFieldsValuesTuple> m_toSync;

  private:
    string name_;
    Table table_;
};

class Orch
{
  public:
    virtual ~Orch() = default;
};

template <typename Base>
class Directory
{
  public:
    template <typename U>
    void set(U value)
    {
        values_[type_index(typeid(U))] = value;
    }

    template <typename U>
    U get() const
    {
        auto it = values_.find(type_index(typeid(U)));
        if (it == values_.end())
        {
            return nullptr;
        }
        return static_cast<U>(it->second);
    }

    void clear()
    {
        values_.clear();
    }

  private:
    unordered_map<type_index, Base> values_;
};

struct NextHopGroup
{
};

template <typename T>
class NhgOrchCommon : public Orch
{
  public:
    NhgOrchCommon(DBConnector *, const string &) {}
    void execute(Consumer &consumer) { doTask(consumer); }

  private:
    virtual void doTask(Consumer &consumer) = 0;
};

enum class CrmResourceType
{
    CRM_NEXTHOP_GROUP
};

class CrmOrch : public Orch
{
  public:
    void incCrmResUsedCounter(CrmResourceType) { ++groups_; }
    void decCrmResUsedCounter(CrmResourceType) { --groups_; }
    int groups() const { return groups_; }

  private:
    int groups_{};
};

class RouteOrch : public Orch
{
  public:
    unsigned int getNhgCount() const { return 0; }
    unsigned int getMaxNhgCount() const { return 1024; }
};

class NhgOrch : public Orch
{
  public:
    static unsigned int getSyncedNhgCount() { return 0; }
};

class Port
{
  public:
    enum Type
    {
        UNKNOWN,
        TUNNEL,
        L2_NHG
    };

    string m_alias;
    sai_object_id_t m_tunnel_id{};
    sai_object_id_t m_bridge_port_id{};
    int m_fdb_count{};
    Type m_type{UNKNOWN};
};

class PortsOrch : public Orch
{
  public:
    bool allPortsReady() const { return true; }

    bool getPort(const string &name, Port &port) const
    {
        auto it = ports_.find(name);
        if (it == ports_.end())
        {
            return false;
        }
        port = it->second;
        return true;
    }

    void addL2NexthopGroup(const string &name, sai_object_id_t oid)
    {
        Port port;
        port.m_alias = name;
        port.m_tunnel_id = oid;
        port.m_type = Port::L2_NHG;
        ports_[name] = port;
    }

    void removeL2NexthopGroup(const Port &port)
    {
        ports_.erase(port.m_alias);
    }

    bool addBridgePort(Port &port)
    {
        port.m_bridge_port_id = ++next_bridge_port_;
        ports_[port.m_alias] = port;
        return true;
    }

    bool removeBridgePort(Port &port)
    {
        port.m_bridge_port_id = 0;
        auto it = ports_.find(port.m_alias);
        if (it != ports_.end())
        {
            it->second.m_bridge_port_id = 0;
        }
        return true;
    }

    void addTunnel(const string &name, sai_object_id_t tunnel_id, bool)
    {
        Port port;
        port.m_alias = name;
        port.m_tunnel_id = tunnel_id;
        port.m_type = Port::TUNNEL;
        ports_[name] = port;
    }

    void removeTunnel(const Port &port)
    {
        ports_.erase(port.m_alias);
    }

  private:
    unordered_map<string, Port> ports_;
    sai_object_id_t next_bridge_port_{0x5000};
};

enum tunnel_user_t
{
    TUNNEL_USER_IMR,
    TUNNEL_USER_MAC,
    TUNNEL_USER_IP
};

struct tunnel_refcnt_t
{
    int imr_refcnt{};
    int mac_refcnt{};
    int ip_refcnt{};
    int spurious_add_imr_refcnt{};
    int spurious_del_imr_refcnt{};
};

constexpr int TNL_CREATION_SRC_EVPN = 1;
constexpr int TUNNEL_MAP_USE_COMMON_ENCAP_DECAP = 1;
#define TUNNELMAP_SET_VLAN(x) ((x) |= 1)
#define TUNNELMAP_SET_VRF(x) ((x) |= 2)

bool bugmc3_tunnel_is_referenced(sai_object_id_t tunnel_id);
extern int bugmc3_tunnel_delete_refusals;

class VxlanTunnelOrch;

class VxlanTunnel : public Orch
{
  public:
    explicit VxlanTunnel(const IpAddress &source_ip) : src_ip_(source_ip), active_(true)
    {
        ids_.tunnel_id = ++next_tunnel_id_;
    }

    VxlanTunnel(const string &name, const IpAddress &source_ip, const IpAddress &, int) :
        tunnel_name_(name), src_ip_(source_ip), active_(true)
    {
        ids_.tunnel_id = ++next_tunnel_id_;
    }

    int getRemoteEndPointRefCnt(const string remote_vtep);
    int getRemoteEndPointIMRRefCnt(const string remote_vtep);
    int getRemoteEndPointIPRefCnt(const string remote_vtep);
    void updateRemoteEndPointRefCnt(bool inc, tunnel_refcnt_t &counts, tunnel_user_t user);
    void updateRemoteEndPointIpRef(const string remote_vtep, bool inc);
    void eraseRemoteEndPoint(const string remote_vtep);
    bool createDynamicDIPTunnel(const string dip, tunnel_user_t user);
    bool deleteDynamicDIPTunnel(const string dip, tunnel_user_t user, bool update_refcnt = true);
    void cleanupDynamicDIPTunnel(const string remote_vtep);

    bool isActive() const { return active_; }
    IpAddress getSrcIP() const { return src_ip_; }
    sai_object_id_t getTunnelId() const { return ids_.tunnel_id; }
    bool createTunnelHw(uint8_t, int, bool) { active_ = true; return true; }
    bool deleteTunnelHw(uint8_t, int, bool)
    {
        if (bugmc3_tunnel_is_referenced(ids_.tunnel_id))
        {
            ++bugmc3_tunnel_delete_refusals;
            return false;
        }
        active_ = false;
        return true;
    }
    void deletePendingSIPTunnel() {}
    bool isTunnelReferenced() const { return !tnl_users_.empty(); }

    bool del_tnl_hw_pending{};
    unordered_map<string, tunnel_refcnt_t> tnl_users_;
    IpAddress src_ip_;

  private:
    struct
    {
        sai_object_id_t tunnel_id{};
    } ids_;
    string tunnel_name_;
    bool active_{};
    inline static sai_object_id_t next_tunnel_id_{0x7000};
};

class VxlanTunnelOrch : public Orch
{
  public:
    bool addTunnelUser(const string remote_vtep, uint32_t vni_id, uint32_t vlan,
                       tunnel_user_t user, sai_object_id_t vrf_id);
    bool delTunnelUser(const string remote_vtep, uint32_t vni_id, uint32_t vlan,
                       tunnel_user_t user, sai_object_id_t vrf_id);

    bool isDipTunnelsSupported() const { return true; }
    void getTunnelNameFromDIP(const string &dip, string &name) const { name = "EVPN_" + dip; }
    string getTunnelPortName(const string &dip, bool local = false) const
    {
        return (local ? "Port_SRC_VTEP_" : "Port_EVPN_") + dip;
    }
    bool getTunnelPort(const string &dip, Port &port, bool = true) const;
    void addTunnel(const string &name, VxlanTunnel *tunnel) { vxlan_tunnel_table_[name] = tunnel; }
    VxlanTunnel *getVxlanTunnel(const string &name) const
    {
        auto it = vxlan_tunnel_table_.find(name);
        return it == vxlan_tunnel_table_.end() ? nullptr : it->second;
    }
    bool delTunnel(const string &name)
    {
        auto it = vxlan_tunnel_table_.find(name);
        if (it == vxlan_tunnel_table_.end())
        {
            return false;
        }
        delete it->second;
        vxlan_tunnel_table_.erase(it);
        return true;
    }
    void deleteTunnelPort(Port &port);

  private:
    unordered_map<string, VxlanTunnel *> vxlan_tunnel_table_;
};

class EvpnNvoOrch : public Orch
{
  public:
    explicit EvpnNvoOrch(VxlanTunnel *source) : source_(source) {}
    VxlanTunnel *getEVPNVtep() const { return source_; }

  private:
    VxlanTunnel *source_;
};

class L2NhgOrch : public NhgOrchCommon<NextHopGroup>
{
  public:
    L2NhgOrch(DBConnector *appDbConnector, string appL2NhgTable);
    ~L2NhgOrch();
    string getNextHopGroupPortName(const string &nhg_id);
    unsigned long getL2NhgCount();
    unsigned long getNumL2NhgNextHops(const string &nhg_id);
    unsigned long getL2NhVtepRefCount(const string &nhg_id);
    bool hasActiveL2Nhg(const string &nhg_id);
    bool isL2NextHop(const string &nhg_id);

  private:
    vector<Table *> m_appTables;

    struct l2nhg_vtep_info
    {
        string ip;
        int ref_count;
        string source_vtep;
    };
    unordered_map<string, l2nhg_vtep_info> m_nhg_vtep;

    struct NhIds
    {
        sai_object_id_t nhgm_oid;
        sai_object_id_t nh_oid;
    };

    struct l2nhg_nh_info
    {
        map<string, NhIds> next_hops;
        sai_object_id_t oid;
        bool is_active = false;
        string source_vtep;
    };
    unordered_map<string, l2nhg_nh_info> m_nhg_nh;

    bool deleteL2NextHop(string nhg_id);
    bool deleteL2NextHopGroup(string nhg_id);
    bool addL2NextHopGroupEntry(string nhg_id, string nh_ids, string source_vtep = "");
    bool removeSaiNextHop(NhIds nh_ids);
    pair<sai_object_id_t, sai_object_id_t> createSaiNextHop(sai_object_id_t l2_nhg_id,
                                                            sai_object_id_t tunnel_id,
                                                            const string &remote_vtep_ip);
    bool removeSaiNextHopGroup(sai_object_id_t l2_nhg_id);
    sai_object_id_t createSaiNextHopGroup();
    bool deleteL2Nhg(string &key, Consumer &consumer);
    bool updateL2Nhg(string &key, KeyOpFieldsValuesTuple &tuple, Consumer &consumer);
    bool updateL2NhgVtepIp(string nh_id, string new_vtep_ip);
    void doL2NhgTask(Consumer &consumer);
    void doTask(Consumer &consumer) override;
};

enum task_process_status
{
    task_success,
    task_failed
};

inline task_process_status handleSaiCreateStatus(int, sai_status_t) { return task_success; }
inline task_process_status handleSaiRemoveStatus(int, sai_status_t) { return task_success; }
inline bool parseHandleSaiStatusFailure(task_process_status) { return false; }

namespace bugmc3
{
struct NextHopRecord
{
    string endpoint;
    sai_object_id_t tunnel_id{};
};

struct MemberRecord
{
    sai_object_id_t group_id{};
    sai_object_id_t next_hop_id{};
};

inline sai_object_id_t next_oid = 0x9000;
inline unordered_map<sai_object_id_t, NextHopRecord> next_hops;
inline unordered_map<sai_object_id_t, MemberRecord> members;
inline set<sai_object_id_t> groups;

inline sai_status_t create_group(sai_object_id_t *oid, sai_object_id_t, uint32_t, const sai_attribute_t *)
{
    *oid = ++next_oid;
    groups.insert(*oid);
    return SAI_STATUS_SUCCESS;
}

inline sai_status_t remove_group(sai_object_id_t oid)
{
    groups.erase(oid);
    return SAI_STATUS_SUCCESS;
}

inline sai_status_t create_next_hop(sai_object_id_t *oid, sai_object_id_t, uint32_t count,
                                    const sai_attribute_t *attrs)
{
    NextHopRecord record;
    for (uint32_t i = 0; i < count; ++i)
    {
        if (attrs[i].id == SAI_NEXT_HOP_ATTR_IP)
        {
            record.endpoint = attrs[i].value.ipaddr.text;
        }
        else if (attrs[i].id == SAI_NEXT_HOP_ATTR_TUNNEL_ID)
        {
            record.tunnel_id = attrs[i].value.oid;
        }
    }
    *oid = ++next_oid;
    next_hops[*oid] = record;
    return SAI_STATUS_SUCCESS;
}

inline sai_status_t remove_next_hop(sai_object_id_t oid)
{
    next_hops.erase(oid);
    return SAI_STATUS_SUCCESS;
}

inline sai_status_t create_member(sai_object_id_t *oid, sai_object_id_t, uint32_t count,
                                  const sai_attribute_t *attrs)
{
    MemberRecord record;
    for (uint32_t i = 0; i < count; ++i)
    {
        if (attrs[i].id == SAI_NEXT_HOP_GROUP_MEMBER_ATTR_NEXT_HOP_GROUP_ID)
        {
            record.group_id = attrs[i].value.oid;
        }
        else if (attrs[i].id == SAI_NEXT_HOP_GROUP_MEMBER_ATTR_NEXT_HOP_ID)
        {
            record.next_hop_id = attrs[i].value.oid;
        }
    }
    *oid = ++next_oid;
    members[*oid] = record;
    return SAI_STATUS_SUCCESS;
}

inline sai_status_t remove_member(sai_object_id_t oid)
{
    members.erase(oid);
    return SAI_STATUS_SUCCESS;
}

inline vector<string> member_endpoints()
{
    vector<string> endpoints;
    for (const auto &entry : members)
    {
        auto next_hop = next_hops.find(entry.second.next_hop_id);
        if (next_hop != next_hops.end())
        {
            endpoints.push_back(next_hop->second.endpoint);
        }
    }
    sort(endpoints.begin(), endpoints.end());
    return endpoints;
}
} // namespace bugmc3

inline int bugmc3_tunnel_delete_refusals = 0;

inline bool bugmc3_tunnel_is_referenced(sai_object_id_t tunnel_id)
{
    for (const auto &member : bugmc3::members)
    {
        auto next_hop = bugmc3::next_hops.find(member.second.next_hop_id);
        if (next_hop != bugmc3::next_hops.end() && next_hop->second.tunnel_id == tunnel_id)
        {
            return true;
        }
    }
    return false;
}

inline sai_next_hop_group_api_t bugmc3_group_api = {
    bugmc3::create_group,
    bugmc3::remove_group,
    bugmc3::create_member,
    bugmc3::remove_member,
};
inline sai_next_hop_api_t bugmc3_next_hop_api = {
    bugmc3::create_next_hop,
    bugmc3::remove_next_hop,
};

inline Directory<Orch *> gDirectory;
inline RouteOrch *gRouteOrch = nullptr;
inline PortsOrch *gPortsOrch = nullptr;
inline CrmOrch *gCrmOrch = nullptr;
inline NhgOrch *gNhgOrch = nullptr;
inline sai_object_id_t gSwitchId = 1;
inline sai_next_hop_group_api_t *sai_next_hop_group_api = &bugmc3_group_api;
inline sai_next_hop_api_t *sai_next_hop_api = &bugmc3_next_hop_api;

inline bool VxlanTunnelOrch::getTunnelPort(const string &dip, Port &port, bool) const
{
    return gPortsOrch->getPort(getTunnelPortName(dip), port);
}

inline void VxlanTunnelOrch::deleteTunnelPort(Port &port)
{
    gPortsOrch->removeBridgePort(port);
    gPortsOrch->removeTunnel(port);
}
