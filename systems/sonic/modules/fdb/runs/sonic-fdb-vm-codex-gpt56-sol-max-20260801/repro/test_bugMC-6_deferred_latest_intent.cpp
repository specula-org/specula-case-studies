/*
 * MC-6 Level-0 reproduction body.
 *
 * This file is included from fdborch_vxlan_ut.cpp so it can reuse the upstream
 * fixture. Every trigger operation goes through the same AppDB Table/Consumer
 * entry points as orchagent. The capability hook only selects a valid P2MP-only
 * SAI platform; it does not alter FdbOrch logic or state.
 */

struct VxlanFdbOrchP2mpTest : public VxlanFdbOrchTest
{
    std::unique_ptr<vxlanorch_sai_wrap_ut::TunnelPeerModeHookGuard> peer_mode_guard;
    VxlanTunnelMapOrch *vxlan_tunnel_map_orch = nullptr;
    EvpnRemoteVnip2mpOrch *remote_vni_orch = nullptr;

    void SetUp() override
    {
        peer_mode_guard.reset(new vxlanorch_sai_wrap_ut::TunnelPeerModeHookGuard(
                vxlanorch_sai_wrap_ut::setTunnelPeerModeP2mpOnly));
        VxlanFdbOrchTest::SetUp();

        // ut_saihelper omits L2MC because most mock tests do not exercise P2MP;
        // production initSaiApi queries it before constructing the orchs.
        ASSERT_EQ(sai_api_query(SAI_API_L2MC_GROUP,
                                reinterpret_cast<void **>(&sai_l2mc_group_api)),
                  SAI_STATUS_SUCCESS);

        // Mirror orchagent/main.cpp startup: VXLAN tunnel creation requires the
        // process-wide underlay loopback RIF created before orchestration starts.
        vector<sai_attribute_t> underlay_attrs(3);
        underlay_attrs[0].id = SAI_ROUTER_INTERFACE_ATTR_VIRTUAL_ROUTER_ID;
        underlay_attrs[0].value.oid = gVirtualRouterId;
        underlay_attrs[1].id = SAI_ROUTER_INTERFACE_ATTR_TYPE;
        underlay_attrs[1].value.s32 = SAI_ROUTER_INTERFACE_TYPE_LOOPBACK;
        underlay_attrs[2].id = SAI_ROUTER_INTERFACE_ATTR_MTU;
        underlay_attrs[2].value.u32 = 9100;
        ASSERT_EQ(pold_sai_router_intfs_api->create_router_interface(
                          &gUnderlayIfId, gSwitchId,
                          static_cast<uint32_t>(underlay_attrs.size()),
                          underlay_attrs.data()),
                  SAI_STATUS_SUCCESS);
        gDirectory.set(gVrfOrch);

        ASSERT_FALSE(m_vxlanTunnelOrch->isDipTunnelsSupported());
        vxlan_tunnel_map_orch = new VxlanTunnelMapOrch(
                m_app_db.get(), APP_VXLAN_TUNNEL_MAP_TABLE_NAME);
        remote_vni_orch = new EvpnRemoteVnip2mpOrch(
                m_app_db.get(), APP_VXLAN_REMOTE_VNI_TABLE_NAME);
        gDirectory.set(vxlan_tunnel_map_orch);
        gDirectory.set(remote_vni_orch);
    }

    void TearDown() override
    {
        delete remote_vni_orch;
        remote_vni_orch = nullptr;
        delete vxlan_tunnel_map_orch;
        vxlan_tunnel_map_orch = nullptr;
        VxlanFdbOrchTest::TearDown();
        peer_mode_guard.reset();
    }
};

TEST_F(VxlanFdbOrchP2mpTest, DeferredLatestIntentProgramsObsoleteEndpoint)
{
    const string source_vtep = "10.0.0.1";
    const string obsolete_endpoint = "10.0.0.101";
    const string latest_endpoint = "10.0.0.102";
    const string tunnel_name = "tunnel_mc6";
    const string fdb_key = "Vlan40:02:11:22:33:44:66";
    const string vni = "1000";

    // Normal startup and VLAN configuration through PortsOrch's AppDB consumer.
    Table port_table(m_app_db.get(), APP_PORT_TABLE_NAME);
    const auto ports = ut_helper::getInitialSaiPorts();
    for (const auto &port : ports)
    {
        port_table.set(port.first, port.second);
    }
    port_table.set("PortConfigDone", { { "count", to_string(ports.size()) } });
    port_table.set("PortInitDone", { { "lanes", "0" } });
    m_portsOrch->addExistingData(&port_table);
    static_cast<Orch *>(m_portsOrch.get())->doTask();

    Table vlan_table(m_app_db.get(), APP_VLAN_TABLE_NAME);
    vlan_table.set(VLAN40, { { "admin_status", "up" }, { "mtu", "9100" } });
    m_portsOrch->addExistingData(&vlan_table);
    static_cast<Orch *>(m_portsOrch.get())->doTask();

    Port vlan;
    ASSERT_TRUE(m_portsOrch->getPort(VLAN40, vlan));

    // Normal tunnel, NVO, and local VNI-map operations. On P2MP hardware the
    // map operation creates the shared source-tunnel bridge port.
    Table tunnel_table(m_app_db.get(), APP_VXLAN_TUNNEL_TABLE_NAME);
    tunnel_table.set(tunnel_name, { { "src_ip", source_vtep } });
    m_vxlanTunnelOrch->addExistingData(&tunnel_table);
    static_cast<Orch *>(m_vxlanTunnelOrch)->doTask();
    ASSERT_TRUE(m_vxlanTunnelOrch->isTunnelExists(tunnel_name));

    Table nvo_table(m_app_db.get(), APP_VXLAN_EVPN_NVO_TABLE_NAME);
    nvo_table.set("nvo_mc6", { { "source_vtep", tunnel_name } });
    m_EvpnNvoOrch->addExistingData(&nvo_table);
    static_cast<Orch *>(m_EvpnNvoOrch)->doTask();
    ASSERT_NE(m_EvpnNvoOrch->getEVPNVtep(), nullptr);

    Table tunnel_map_table(m_app_db.get(), APP_VXLAN_TUNNEL_MAP_TABLE_NAME);
    tunnel_map_table.set(tunnel_name + ":map_mc6",
                         { { "vni", vni }, { "vlan", VLAN40 } });
    vxlan_tunnel_map_orch->addExistingData(&tunnel_map_table);
    static_cast<Orch *>(vxlan_tunnel_map_orch)->doTask();
    ASSERT_TRUE(vxlan_tunnel_map_orch->isTunnelMapExists(tunnel_name + ":map_mc6"));

    const string source_port_name =
            m_vxlanTunnelOrch->getTunnelPortName(source_vtep, true);
    Port source_port;
    ASSERT_TRUE(m_portsOrch->getPort(source_port_name, source_port));
    ASSERT_NE(source_port.m_bridge_port_id, SAI_NULL_OBJECT_ID);

    int sai_create_calls = 0;
    string programmed_endpoint = "none";
    EXPECT_CALL(*mock_sai_fdb_api, create_fdb_entry)
        .Times(1)
        .WillOnce(testing::Invoke(
            [&](const sai_fdb_entry_t *, uint32_t attr_count,
                const sai_attribute_t *attrs) -> sai_status_t
            {
                ++sai_create_calls;
                for (uint32_t i = 0; i < attr_count; ++i)
                {
                    if (attrs[i].id != SAI_FDB_ENTRY_ATTR_ENDPOINT_IP)
                    {
                        continue;
                    }
                    EXPECT_EQ(attrs[i].value.ipaddr.addr_family,
                              SAI_IP_ADDR_FAMILY_IPV4);
                    if (attrs[i].value.ipaddr.addr.ip4 ==
                            IpAddress(obsolete_endpoint).getV4Addr())
                    {
                        programmed_endpoint = obsolete_endpoint;
                    }
                    else if (attrs[i].value.ipaddr.addr.ip4 ==
                             IpAddress(latest_endpoint).getV4Addr())
                    {
                        programmed_endpoint = latest_endpoint;
                    }
                    else
                    {
                        programmed_endpoint = "unexpected";
                    }
                }
                return SAI_STATUS_SUCCESS;
            }));

    // Two legitimate same-key SETs arrive while neither endpoint is a VLAN
    // member. This matches RR003 states 2-3; AppDB's latest value is p2.
    ProducerStateTable vxlan_fdb_producer(m_app_db.get(),
                                          APP_VXLAN_FDB_TABLE_NAME);
    Table vxlan_fdb_table(m_app_db.get(), APP_VXLAN_FDB_TABLE_NAME);
    vxlan_fdb_producer.set(fdb_key,
                           { { "vni", vni }, { "type", "dynamic" },
                             { "remote_vtep", obsolete_endpoint } });
    gFdbOrch->addExistingData(&vxlan_fdb_table);
    static_cast<Orch *>(gFdbOrch)->doTask();
    ASSERT_EQ(sai_create_calls, 0);

    vxlan_fdb_producer.set(fdb_key,
                           { { "vni", vni }, { "type", "dynamic" },
                             { "remote_vtep", latest_endpoint } });
    gFdbOrch->addExistingData(&vxlan_fdb_table);
    static_cast<Orch *>(gFdbOrch)->doTask();
    ASSERT_EQ(sai_create_calls, 0);

    string appdb_desired;
    ASSERT_TRUE(vxlan_fdb_table.hget(fdb_key, "remote_vtep", appdb_desired));
    ASSERT_EQ(appdb_desired, latest_endpoint);

    cout << "MC-6 escalation_level=0" << endl;
    cout << "normal_ops=VXLAN_FDB_SET(p1),VXLAN_FDB_SET(p2),REMOTE_VNI_ADD(p1)" << endl;
    cout << "sai_calls_before_dependency=" << sai_create_calls << endl;
    cout << "appdb_latest_endpoint=" << appdb_desired << endl;

    // Normal REMOTE_VNI_TABLE add for p1 creates its endpoint membership and
    // emits the ordinary VLAN-member notification (counterexample state 4).
    Table remote_vni_table(m_app_db.get(), APP_VXLAN_REMOTE_VNI_TABLE_NAME);
    remote_vni_table.set(VLAN40 + remote_vni_table.getTableNameSeparator() +
                                 obsolete_endpoint,
                         { { "vni", vni } });
    remote_vni_orch->addExistingData(&remote_vni_table);
    static_cast<Orch *>(remote_vni_orch)->doTask();

    Port replay_vlan;
    Port replay_port;
    ASSERT_TRUE(m_portsOrch->getPort(VLAN40, replay_vlan));
    ASSERT_TRUE(m_portsOrch->getPort(source_port_name, replay_port));
    ASSERT_TRUE(m_portsOrch->isVlanMember(
            replay_vlan, replay_port, obsolete_endpoint));
    ASSERT_FALSE(m_portsOrch->isVlanMember(
            replay_vlan, replay_port, latest_endpoint));
    ASSERT_EQ(sai_create_calls, 1);
    ASSERT_EQ(programmed_endpoint, obsolete_endpoint);
    cout << "dependency_endpoint_member=" << obsolete_endpoint << endl;

    // No executor/timer autonomously revisits the still-deferred p2 value.
    for (int i = 0; i < 3; ++i)
    {
        static_cast<Orch *>(gFdbOrch)->doTask();
        static_cast<Orch *>(remote_vni_orch)->doTask();
    }
    ASSERT_EQ(sai_create_calls, 1);
    ASSERT_EQ(programmed_endpoint, obsolete_endpoint);

    cout << "sai_create_endpoint=" << programmed_endpoint << endl;
    cout << "sai_create_calls_after_idle_cycles=" << sai_create_calls << endl;
    cout << "expected_endpoint=" << latest_endpoint << endl;
    cout << "persistent_without_new_dependency=yes" << endl;
    cout << "BUG_TRIGGERED obsolete_destination_visible_to_sai=yes" << endl;
}
