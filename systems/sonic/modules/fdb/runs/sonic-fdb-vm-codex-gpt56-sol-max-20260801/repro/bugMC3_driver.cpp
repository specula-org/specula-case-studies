#include "bugMC3_harness.hpp"

namespace
{
bool submit(L2NhgOrch &orch, const string &key, const string &op,
            vector<FieldValueTuple> fields = {})
{
    Consumer consumer(APP_L2_NEXTHOP_GROUP_TABLE_NAME);
    consumer.m_toSync.emplace(key, KeyOpFieldsValuesTuple{key, op, std::move(fields)});
    static_cast<NhgOrchCommon<NextHopGroup> &>(orch).execute(consumer);
    return consumer.m_toSync.empty();
}

bool tunnel_exists(VxlanTunnelOrch &orch, const string &endpoint)
{
    Port port;
    return orch.getTunnelPort(endpoint, port, false);
}

bool dynamic_tunnel_exists(VxlanTunnelOrch &orch, const string &endpoint)
{
    string name;
    orch.getTunnelNameFromDIP(endpoint, name);
    return orch.getVxlanTunnel(name) != nullptr;
}

string only_member_endpoint()
{
    const auto endpoints = bugmc3::member_endpoints();
    if (endpoints.size() != 1)
    {
        return string("count=") + to_string(endpoints.size());
    }
    return endpoints.front();
}
} // namespace

int main()
{
    const string old_endpoint = "192.0.2.10";
    const string new_endpoint = "192.0.2.20";

    RouteOrch route;
    PortsOrch ports;
    CrmOrch crm;
    NhgOrch nhg;
    VxlanTunnelOrch vxlan;
    VxlanTunnel source_vtep(IpAddress("198.51.100.1"));
    EvpnNvoOrch evpn_nvo(&source_vtep);
    DBConnector app_db;

    gDirectory.clear();
    gRouteOrch = &route;
    gPortsOrch = &ports;
    gCrmOrch = &crm;
    gNhgOrch = &nhg;
    gDirectory.set(&vxlan);
    gDirectory.set(&evpn_nvo);

    // Normal EVPN/IMET operations establish both dynamic DIP tunnels.
    if (!vxlan.addTunnelUser(old_endpoint, 1000, 100, TUNNEL_USER_IMR, 0) ||
        !vxlan.addTunnelUser(new_endpoint, 1000, 100, TUNNEL_USER_IMR, 0))
    {
        cerr << "HARNESS_ERROR tunnel setup failed\n";
        return 2;
    }

    L2NhgOrch l2nhg(&app_db, APP_L2_NEXTHOP_GROUP_TABLE_NAME);

    // These are the exact normal APP_DB events produced for a gateway NH,
    // an NHG containing it, and replacement of that same gateway NH ID.
    if (!submit(l2nhg, "10", SET_COMMAND, {{"remote_vtep", old_endpoint}}) ||
        !submit(l2nhg, "100", SET_COMMAND, {{"nexthop_group", "10"}}))
    {
        cerr << "HARNESS_ERROR initial L2 NHG operations did not complete\n";
        return 2;
    }

    cout << "LEVEL=0 interface=L2_NEXTHOP_GROUP_TABLE normal_SET_DEL no_failpoints\n";
    cout << "INITIAL member_endpoint=" << only_member_endpoint()
         << " old_ip_ref=" << source_vtep.getRemoteEndPointIPRefCnt(old_endpoint)
         << " new_ip_ref=" << source_vtep.getRemoteEndPointIPRefCnt(new_endpoint)
         << " l2_ref=" << l2nhg.getL2NhVtepRefCount("10") << "\n";

    if (!submit(l2nhg, "10", SET_COMMAND, {{"remote_vtep", new_endpoint}}))
    {
        cerr << "HARNESS_ERROR replacement event was left pending\n";
        return 2;
    }

    const int replacement_old_ip_ref = source_vtep.getRemoteEndPointIPRefCnt(old_endpoint);
    const int replacement_new_ip_ref = source_vtep.getRemoteEndPointIPRefCnt(new_endpoint);
    const string replacement_member = only_member_endpoint();

    cout << "REPLACEMENT actual_member_endpoint=" << replacement_member
         << " actual_old_ip_ref=" << replacement_old_ip_ref
         << " actual_new_ip_ref=" << replacement_new_ip_ref
         << " l2_ref=" << l2nhg.getL2NhVtepRefCount("10") << "\n";
    cout << "REPLACEMENT expected_member_endpoint=" << new_endpoint
         << " expected_old_ip_ref=0 expected_new_ip_ref=1\n";

    // A duplicate/resend is a normal convergence mechanism. It must not be
    // able to repair the state merely because the cached IP was already set.
    if (!submit(l2nhg, "10", SET_COMMAND, {{"remote_vtep", new_endpoint}}))
    {
        cerr << "HARNESS_ERROR resend event was left pending\n";
        return 2;
    }
    const bool resend_permanent =
        source_vtep.getRemoteEndPointIPRefCnt(old_endpoint) == replacement_old_ip_ref &&
        source_vtep.getRemoteEndPointIPRefCnt(new_endpoint) == replacement_new_ip_ref;
    cout << "RESEND old_ip_ref=" << source_vtep.getRemoteEndPointIPRefCnt(old_endpoint)
         << " new_ip_ref=" << source_vtep.getRemoteEndPointIPRefCnt(new_endpoint)
         << " corrected=" << (resend_permanent ? "no" : "yes") << "\n";

    // Exercise the real downstream consumer extracted unmodified from
    // VxlanTunnelOrch::delTunnelUser(): withdraw the new endpoint's IMR user.
    vxlan.delTunnelUser(new_endpoint, 1000, 100, TUNNEL_USER_IMR, 0);
    const bool new_tunnel_after_imr_delete = tunnel_exists(vxlan, new_endpoint);
    const bool new_dynamic_tunnel_after_imr_delete = dynamic_tunnel_exists(vxlan, new_endpoint);
    const size_t members_after_new_imr_delete = bugmc3::members.size();
    cout << "NEW_IMR_DELETE new_tunnel_present=" << (new_tunnel_after_imr_delete ? 1 : 0)
         << " new_dynamic_tunnel_cached=" << (new_dynamic_tunnel_after_imr_delete ? 1 : 0)
         << " active_sai_members=" << members_after_new_imr_delete
         << " member_endpoint=" << only_member_endpoint()
         << " sai_tunnel_delete_refusals=" << bugmc3_tunnel_delete_refusals << "\n";
    cout << "NEW_IMR_DELETE expected_new_tunnel_present=1 expected_new_dynamic_tunnel_cached=1 "
            "while_active_sai_members=1\n";

    // Withdraw the old endpoint too. Its stale IP credit retains a tunnel with
    // no SAI member pointing to it.
    vxlan.delTunnelUser(old_endpoint, 1000, 100, TUNNEL_USER_IMR, 0);
    const bool old_tunnel_leaked = tunnel_exists(vxlan, old_endpoint);
    cout << "OLD_IMR_DELETE old_tunnel_present=" << (old_tunnel_leaked ? 1 : 0)
         << " old_total_ref=" << source_vtep.getRemoteEndPointRefCnt(old_endpoint)
         << " old_ip_ref=" << source_vtep.getRemoteEndPointIPRefCnt(old_endpoint) << "\n";
    cout << "OLD_IMR_DELETE expected_old_tunnel_present=0 expected_old_total_ref=-1\n";

    // Exercise normal group cleanup. It removes the SAI member but addresses
    // the new endpoint, so the stale old credit remains after cleanup.
    if (!submit(l2nhg, "100", DEL_COMMAND))
    {
        cerr << "HARNESS_ERROR group delete event was left pending\n";
        return 2;
    }
    cout << "GROUP_DELETE active_sai_members=" << bugmc3::members.size()
         << " stale_old_tunnel_present=" << (tunnel_exists(vxlan, old_endpoint) ? 1 : 0)
         << " stale_old_ip_ref=" << source_vtep.getRemoteEndPointIPRefCnt(old_endpoint) << "\n";

    const bool accounting_mismatch =
        replacement_member == new_endpoint &&
        replacement_old_ip_ref == 1 &&
        replacement_new_ip_ref == 0;
    const bool consumer_harm =
        !new_tunnel_after_imr_delete && !new_dynamic_tunnel_after_imr_delete &&
        members_after_new_imr_delete == 1 && bugmc3_tunnel_delete_refusals == 1;
    const bool cleanup_did_not_heal =
        bugmc3::members.empty() && tunnel_exists(vxlan, old_endpoint) &&
        source_vtep.getRemoteEndPointIPRefCnt(old_endpoint) == 1;

    if (accounting_mismatch && resend_permanent && consumer_harm &&
        old_tunnel_leaked && cleanup_did_not_heal)
    {
        cout << "BUG_TRIGGERED stale_old_credit=1 missing_new_credit=1 "
                "new_tunnel_deleted_while_member_live=1 old_tunnel_leaked=1 permanent_after_resend=1\n";
        return 0;
    }

    cout << "BUG_NOT_TRIGGERED accounting_mismatch=" << accounting_mismatch
         << " permanent_after_resend=" << resend_permanent
         << " consumer_harm=" << consumer_harm
         << " old_tunnel_leaked=" << old_tunnel_leaked
         << " cleanup_did_not_heal=" << cleanup_did_not_heal << "\n";
    return 1;
}
