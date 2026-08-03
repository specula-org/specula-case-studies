// MC-7 reproduction: startup NHG dump is lost before EVPN NVO readiness.
//
// Escalation record:
//   Level 0: an isolated real kernel/netlink + real fdbsyncd run was attempted.
//            Linux accepted a public `ip nexthop add ... fdb` object and the
//            daemon processed CONFIG_DB, but this host's 5.15/libnl runtime did
//            not dispatch either dump or live FDB-nexthop records to onMsgNhg.
//   Level 1: readiness was delayed/republished and a post-readiness live NHG
//            was added; the runtime still dispatched no NHG record.
//   Level 2 (this program): inject the valid RTM_NEWNEXTHOP dump record at the
//            public NetMsg entrypoint. The injected precondition is exactly the
//            supplied counterexample's State 3 MCKernelNhgChangeWhileDown(g1),
//            delivered by the startup-dump step represented at State 5. The
//            real public-API sequence is: stop fdbsyncd; `ip nexthop add id
//            268435458 via 192.0.2.1 fdb`; restart fdbsyncd; kernel answers its
//            RTM_GETNEXTHOP request with this RTM_NEWNEXTHOP record.
//
// This test compiles the unmodified production fdbsync.cpp and uses real
// swsscommon Redis ProducerStateTable/ConsumerStateTable implementations. The
// latter is the APP_DB transport used by Orch/L2NhgOrch in production.

#include <arpa/inet.h>
#include <linux/nexthop.h>
#include <linux/rtnetlink.h>
#include <netinet/in.h>

#include <cstdlib>
#include <cstring>
#include <deque>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include "consumerstatetable.h"
#include "dbconnector.h"
#include "fdbsyncd/fdbsync.h"
#include "producerstatetable.h"
#include "redispipeline.h"
#include "schema.h"

using namespace swss;

namespace
{

constexpr std::size_t kMessageBytes = 1024;
constexpr uint32_t kEarlyNhId = 268435458;
constexpr uint32_t kControlNhId = 268435459;

struct FreeDeleter
{
    void operator()(nlmsghdr *message) const
    {
        std::free(message);
    }
};

using MessagePtr = std::unique_ptr<nlmsghdr, FreeDeleter>;

MessagePtr makeFdbNexthop(uint32_t nhid, const char *remoteVtep)
{
    auto *message = static_cast<nlmsghdr *>(std::calloc(1, NLMSG_SPACE(kMessageBytes)));
    if (message == nullptr)
    {
        throw std::bad_alloc();
    }

    message->nlmsg_type = RTM_NEWNEXTHOP;
    message->nlmsg_flags = NLM_F_CREATE | NLM_F_REQUEST;
    message->nlmsg_len = NLMSG_LENGTH(0);

    auto *nhm = static_cast<nhmsg *>(NLMSG_DATA(message));
    nhm->nh_family = AF_INET;
    message->nlmsg_len += RTA_ALIGN(sizeof(*nhm));

    auto *attribute = reinterpret_cast<rtattr *>(
        reinterpret_cast<char *>(nhm) + NLMSG_ALIGN(sizeof(*nhm)));
    int remaining = static_cast<int>(kMessageBytes);

    attribute->rta_type = NHA_ID;
    attribute->rta_len = RTA_LENGTH(sizeof(nhid));
    std::memcpy(RTA_DATA(attribute), &nhid, sizeof(nhid));
    message->nlmsg_len += RTA_ALIGN(attribute->rta_len);

    attribute = RTA_NEXT(attribute, remaining);
    attribute->rta_type = NHA_GATEWAY;
    attribute->rta_len = RTA_LENGTH(sizeof(in_addr));
    if (inet_pton(AF_INET, remoteVtep, RTA_DATA(attribute)) != 1)
    {
        std::free(message);
        throw std::runtime_error("invalid control VTEP");
    }
    message->nlmsg_len += RTA_ALIGN(attribute->rta_len);

    attribute = RTA_NEXT(attribute, remaining);
    attribute->rta_type = NHA_FDB;
    attribute->rta_len = RTA_LENGTH(0);
    message->nlmsg_len += RTA_ALIGN(attribute->rta_len);

    return MessagePtr(message);
}

bool containsSetFor(const std::deque<KeyOpFieldsValuesTuple> &events, uint32_t nhid)
{
    const std::string expectedKey = std::to_string(nhid);
    for (const auto &event : events)
    {
        if (kfvKey(event) == expectedKey && kfvOp(event) == SET_COMMAND)
        {
            return true;
        }
    }
    return false;
}

std::vector<FieldValueTuple> fieldsForSet(
    const std::deque<KeyOpFieldsValuesTuple> &events,
    uint32_t nhid)
{
    const std::string expectedKey = std::to_string(nhid);
    for (const auto &event : events)
    {
        if (kfvKey(event) == expectedKey && kfvOp(event) == SET_COMMAND)
        {
            return kfvFieldsValues(event);
        }
    }
    return {};
}

int fail(const std::string &reason)
{
    std::cerr << "MC7_TEST_FAILURE: " << reason << std::endl;
    return 1;
}

} // namespace

int main()
{
    std::cout << "test=MC-7 startup NHG dump before NVO readiness" << std::endl;
    std::cout << "level=2 (admissible counterexample-state injection)" << std::endl;
    std::cout << "counterexample=spec/output/repair_RR003_MC_hunt_scenario_5_restart_bfs.out"
              << std::endl;
    std::cout << "trace_step=State 3 MCKernelNhgChangeWhileDown(g1), delivered at State 5 startup dump"
              << std::endl;

    DBConnector appDb("APPL_DB", 0);
    RedisPipeline appPipeline(&appDb);
    DBConnector stateDb("STATE_DB", 0);
    DBConnector configDb("CONFIG_DB", 0);

    // The external harness pre-populates VXLAN_EVPN_NVO before construction.
    // SubscriberStateTable legitimately buffers pre-existing CONFIG_DB rows,
    // but fdbsyncd main processes that buffer only after its netlink dumps.
    FdbSync sync(&appPipeline, &stateDb, &configDb);
    ConsumerStateTable l2NhgConsumer(&appDb, APP_L2_NEXTHOP_GROUP_TABLE_NAME);

    std::cout << "initial_nvo_ready=" << sync.m_isEvpnNvoExist << std::endl;
    if (sync.m_isEvpnNvoExist)
    {
        return fail("NVO must begin false before CONFIG_DB is processed");
    }

    // Startup RTM_GETNEXTHOP dump record for a kernel object created while the
    // daemon was down. This enters through the registered public raw handler.
    auto early = makeFdbNexthop(kEarlyNhId, "192.0.2.1");
    sync.onMsgRaw(early.get());
    appPipeline.flush();

    std::deque<KeyOpFieldsValuesTuple> consumerEventsAfterDump;
    l2NhgConsumer.pops(consumerEventsAfterDump);
    bool consumerSawEarlyAfterDump = containsSetFor(consumerEventsAfterDump, kEarlyNhId);
    std::cout << "app_consumer_events_after_dump=" << consumerEventsAfterDump.size() << std::endl;
    std::cout << "app_consumer_saw_early_set_after_dump=" << consumerSawEarlyAfterDump << std::endl;
    if (consumerSawEarlyAfterDump)
    {
        return fail("early record was not gated; current source no longer has MC-7");
    }

    // Normal CONFIG_DB processing makes NVO ready. No private field is changed.
    sync.processCfgEvpnNvo();
    std::cout << "nvo_ready_after_config=" << sync.m_isEvpnNvoExist << std::endl;
    if (!sync.m_isEvpnNvoExist)
    {
        return fail("pre-populated real CONFIG_DB NVO row was not consumed");
    }

    // Exercise another normal, empty CONFIG_DB processing pass. Readiness has
    // no saved record to replay and schedules no second kernel dump.
    sync.processCfgEvpnNvo();
    appPipeline.flush();

    std::deque<KeyOpFieldsValuesTuple> consumerEventsAfterSettle;
    l2NhgConsumer.pops(consumerEventsAfterSettle);
    bool consumerSawEarly = containsSetFor(consumerEventsAfterSettle, kEarlyNhId);
    std::cout << "app_consumer_events_after_settle=" << consumerEventsAfterSettle.size() << std::endl;
    std::cout << "app_consumer_saw_early_set_after_settle=" << consumerSawEarly << std::endl;

    if (consumerSawEarly)
    {
        return fail("a downstream replay unexpectedly repaired the early NHG");
    }

    // Positive control: the identical production handler publishes a later
    // valid record once NVO is ready, and the real APP_DB consumer sees SET.
    auto control = makeFdbNexthop(kControlNhId, "192.0.2.2");
    sync.onMsgRaw(control.get());
    appPipeline.flush();

    std::deque<KeyOpFieldsValuesTuple> controlEvents;
    l2NhgConsumer.pops(controlEvents);
    bool consumerSawControl = containsSetFor(controlEvents, kControlNhId);
    bool consumerSawEarlyAfterControl = containsSetFor(controlEvents, kEarlyNhId);
    std::vector<FieldValueTuple> controlValues = fieldsForSet(controlEvents, kControlNhId);
    std::string controlRemoteVtep;
    for (const auto &field : controlValues)
    {
        if (fvField(field) == "remote_vtep")
        {
            controlRemoteVtep = fvValue(field);
        }
    }

    std::cout << "app_consumer_control_events=" << controlEvents.size() << std::endl;
    std::cout << "app_consumer_live_control_set=" << consumerSawControl << std::endl;
    std::cout << "app_consumer_live_control_fields=" << controlValues.size() << std::endl;
    std::cout << "app_consumer_live_control_remote_vtep=" << controlRemoteVtep << std::endl;
    std::cout << "app_consumer_saw_early_set_after_control=" << consumerSawEarlyAfterControl << std::endl;

    if (!consumerSawControl || controlRemoteVtep != "192.0.2.2")
    {
        return fail("positive control did not traverse handler -> ProducerStateTable -> ConsumerStateTable");
    }
    if (consumerSawEarlyAfterControl)
    {
        return fail("the later unrelated event unexpectedly reconstructed the discarded ID");
    }

    std::cout << "real_consumer=L2NhgOrch APP_DB transport (ConsumerStateTable)" << std::endl;
    std::cout << "correct_expected=both IDs 268435458 and 268435459 published after startup settles"
              << std::endl;
    std::cout << "observed=only post-readiness ID 268435459 is published; startup ID remains absent"
              << std::endl;
    std::cout << "permanent_without_external_resend=yes" << std::endl;
    std::cout << "MC7_REPRODUCED" << std::endl;
    return 0;
}
