// MC-5 reproduction: fpmsyncd's WarmStartHelper publishes RECONCILED while
// reconciliation output is still buffered in RedisPipeline.  This is a Level-2
// test: it instantiates counterexample state 6 through the same public helper
// sequence used by fpmsyncd, then executes the caller-side flush from
// fpmsyncd.cpp.  No production source is modified.

#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <hiredis/hiredis.h>

#include "consumerstatetable.h"
#include "dbconnector.h"
#include "producerstatetable.h"
#include "redispipeline.h"
#include "schema.h"
#include "table.h"
#include "warmRestartHelper.h"

using namespace swss;

namespace
{

class RedisServer
{
  public:
    RedisServer()
    {
        char directoryTemplate[] = "/tmp/mc5-repro-XXXXXX";
        char *created = ::mkdtemp(directoryTemplate);
        if (created == nullptr)
        {
            throw std::runtime_error(std::string("mkdtemp failed: ") + std::strerror(errno));
        }

        directory = created;
        socketPath = directory + "/redis.sock";
        logPath = directory + "/redis.log";
        configPath = directory + "/database_config.json";

        child = ::fork();
        if (child < 0)
        {
            throw std::runtime_error(std::string("fork failed: ") + std::strerror(errno));
        }

        if (child == 0)
        {
            ::execlp("redis-server",
                     "redis-server",
                     "--save", "",
                     "--appendonly", "no",
                     "--port", "0",
                     "--unixsocket", socketPath.c_str(),
                     "--unixsocketperm", "700",
                     "--dir", directory.c_str(),
                     "--logfile", logPath.c_str(),
                     static_cast<char *>(nullptr));
            _exit(127);
        }

        waitUntilReady();
        writeDatabaseConfig();
    }

    RedisServer(const RedisServer &) = delete;
    RedisServer &operator=(const RedisServer &) = delete;

    ~RedisServer()
    {
        if (child > 0)
        {
            ::kill(child, SIGTERM);
            int status = 0;
            while (::waitpid(child, &status, 0) < 0 && errno == EINTR)
            {
            }
        }

        ::unlink(socketPath.c_str());
        ::unlink(configPath.c_str());
        ::unlink(logPath.c_str());
        ::rmdir(directory.c_str());
    }

    const std::string &config() const
    {
        return configPath;
    }

  private:
    void waitUntilReady()
    {
        for (int attempt = 0; attempt < 200; ++attempt)
        {
            redisContext *context = redisConnectUnix(socketPath.c_str());
            if (context != nullptr && context->err == 0)
            {
                redisReply *reply = static_cast<redisReply *>(redisCommand(context, "PING"));
                bool ready = reply != nullptr && reply->type == REDIS_REPLY_STATUS &&
                             std::string(reply->str, reply->len) == "PONG";
                if (reply != nullptr)
                {
                    freeReplyObject(reply);
                }
                redisFree(context);
                if (ready)
                {
                    return;
                }
            }
            else if (context != nullptr)
            {
                redisFree(context);
            }

            int status = 0;
            pid_t result = ::waitpid(child, &status, WNOHANG);
            if (result == child)
            {
                child = -1;
                throw std::runtime_error("redis-server exited before becoming ready");
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        throw std::runtime_error("timed out waiting for redis-server");
    }

    void writeDatabaseConfig()
    {
        std::ofstream out(configPath);
        if (!out)
        {
            throw std::runtime_error("could not create database_config.json");
        }
        out << "{\n"
               "  \"INSTANCES\": {\n"
               "    \"redis\": {\"hostname\": \"127.0.0.1\", \"port\": 0, "
               "\"unix_socket_path\": \""
            << socketPath
            << "\"}\n"
               "  },\n"
               "  \"DATABASES\": {\n"
               "    \"APPL_DB\": {\"id\": 0, \"separator\": \":\", \"instance\": \"redis\"},\n"
               "    \"CONFIG_DB\": {\"id\": 4, \"separator\": \"|\", \"instance\": \"redis\"},\n"
               "    \"STATE_DB\": {\"id\": 6, \"separator\": \"|\", \"instance\": \"redis\"}\n"
               "  },\n"
               "  \"VERSION\": \"1.0\"\n"
               "}\n";
        out.close();
        if (!out)
        {
            throw std::runtime_error("could not finish database_config.json");
        }
    }

    pid_t child{-1};
    std::string directory;
    std::string socketPath;
    std::string logPath;
    std::string configPath;
};

std::string tableField(Table &table, const std::string &key, const std::string &field)
{
    std::string value;
    return table.hget(key, field, value) ? value : "<absent>";
}

long long setCardinality(DBConnector &db, const std::string &key)
{
    redisReply *reply = static_cast<redisReply *>(
        redisCommand(db.getContext(), "SCARD %s", key.c_str()));
    if (reply == nullptr)
    {
        throw std::runtime_error("SCARD returned no reply");
    }
    if (reply->type != REDIS_REPLY_INTEGER)
    {
        freeReplyObject(reply);
        throw std::runtime_error("SCARD returned an unexpected reply type");
    }
    long long result = reply->integer;
    freeReplyObject(reply);
    return result;
}

bool hasField(const std::vector<FieldValueTuple> &fields,
              const std::string &name,
              const std::string &expected)
{
    for (const auto &field : fields)
    {
        if (fvField(field) == name && fvValue(field) == expected)
        {
            return true;
        }
    }
    return false;
}

void require(bool condition, const std::string &message)
{
    if (!condition)
    {
        throw std::runtime_error(message);
    }
}

} // namespace

int main()
{
    try
    {
        std::cout << "LEVEL0_RESULT=UNAVAILABLE"
                  << " reason=fpmsyncd_binary_and_SONiC_DVS_not_available_to_runner\n";
        std::cout << "LEVEL1_RESULT=UNAVAILABLE"
                  << " reason=no_full_daemon_for_timing_only_assistance\n";
        std::cout << "LEVEL2_MODE=STATE_INJECTION"
                  << " trace_step=State_6_MCFpmSyncdWarmRestartTimerExpired_to_State_7_MCNextCompletion\n";
        std::cout << "LEVEL2_REAL_API_SEQUENCE="
                  << "enable_warm_restart->checkAndStart->runRestoration->"
                     "legitimate_route_refresh_and_stale_omission->timer_expiry->"
                     "reconcile->caller_flush\n";

        RedisServer redis;
        SonicDBConfig::initialize(redis.config());

        DBConnector appDb("APPL_DB", 0);
        DBConnector stateDb("STATE_DB", 0);
        DBConnector observerAppDb("APPL_DB", 0);
        DBConnector observerStateDb("STATE_DB", 0);

        Table oldRouteState(&appDb, "ROUTE_TABLE");
        Table warmEnable(&stateDb, STATE_WARM_RESTART_ENABLE_TABLE_NAME);
        Table warmStateSetup(&stateDb, STATE_WARM_RESTART_TABLE_NAME);

        const std::string staleRoute = "10.0.0.0/24";
        const std::string changedRoute = "10.0.1.0/24";
        const std::string newRoute = "10.0.2.0/24";

        // Old-life state retained across warm restart.
        oldRouteState.set(staleRoute, {{"nexthop", "192.0.2.1"}, {"protocol", "bgp"}});
        oldRouteState.set(changedRoute, {{"nexthop", "192.0.2.2"}, {"protocol", "bgp"}});

        // Normal warm-start knobs consumed by WarmStartHelper::checkAndStart().
        warmEnable.hset("system", "enable", "true");
        warmStateSetup.hset("bgp", "restore_count", "0");

        RedisPipeline pipeline(&appDb, 50000);
        ProducerStateTable routeProducer(&pipeline, "ROUTE_TABLE", true);
        WarmStartHelper helper(&pipeline, &routeProducer, "ROUTE_TABLE", "bgp", "bgp");

        require(helper.checkAndStart(), "warm start was not enabled");
        require(helper.runRestoration(), "old route state was not restored");
        require(helper.getState() == WarmStart::RESTORED, "helper did not reach RESTORED");

        // Legitimate refreshed state corresponding to FPM RTM_NEWROUTE messages.
        // Omitting staleRoute corresponds to the normal stale-route delete case.
        helper.insertRefreshMap({changedRoute,
                                 SET_COMMAND,
                                 {{"nexthop", "198.51.100.2"}, {"protocol", "bgp"}}});
        helper.insertRefreshMap({newRoute,
                                 SET_COMMAND,
                                 {{"nexthop", "198.51.100.3"}, {"protocol", "bgp"}}});

        // This is RouteSync::onWarmStartEnd()'s helper call.  It queues one
        // delete, one update, and one add, then synchronously publishes state.
        helper.reconcile();

        Table observedWarmState(&observerStateDb, STATE_WARM_RESTART_TABLE_NAME);
        Table observedRoutes(&observerAppDb, "ROUTE_TABLE");
        std::string externallyVisibleState;
        require(observedWarmState.hget("bgp", "state", externallyVisibleState),
                "external observer could not read bgp warm state");

        const size_t bufferedBeforeFlush = pipeline.size();
        const long long durableBeforeFlush = setCardinality(observerAppDb, "ROUTE_TABLE_KEY_SET");
        const std::string staleBeforeFlush = tableField(observedRoutes, staleRoute, "nexthop");
        const std::string changedBeforeFlush = tableField(observedRoutes, changedRoute, "nexthop");
        const std::string newBeforeFlush = tableField(observedRoutes, newRoute, "nexthop");

        std::cout << "PRE_FLUSH state=" << externallyVisibleState
                  << " pipeline_size=" << bufferedBeforeFlush
                  << " durable_route_queue=" << durableBeforeFlush
                  << " stale_route=" << staleBeforeFlush
                  << " changed_route=" << changedBeforeFlush
                  << " new_route=" << newBeforeFlush << "\n";

        require(externallyVisibleState == "reconciled", "RECONCILED was not externally visible");
        require(bufferedBeforeFlush == 3, "expected delete/update/add to remain buffered");
        require(durableBeforeFlush == 0, "route output was unexpectedly durable before flush");
        require(staleBeforeFlush == "192.0.2.1", "stale route changed before flush");
        require(changedBeforeFlush == "192.0.2.2", "changed route updated before flush");
        require(newBeforeFlush == "<absent>", "new route appeared before flush");
        std::cout << "COUNTEREXAMPLE_STATE_OBSERVED=yes\n";

        // This is the unconditional downstream statement at fpmsyncd.cpp:218.
        pipeline.flush();

        const size_t bufferedAfterFlush = pipeline.size();
        const long long durableAfterFlush = setCardinality(observerAppDb, "ROUTE_TABLE_KEY_SET");
        std::cout << "POST_FLUSH state=" << externallyVisibleState
                  << " pipeline_size=" << bufferedAfterFlush
                  << " durable_route_queue=" << durableAfterFlush << "\n";
        require(bufferedAfterFlush == 0, "caller flush left commands buffered");
        require(durableAfterFlush == 3, "caller flush did not durably publish all route outputs");

        // Exercise the same ConsumerStateTable API RouteOrch uses for APPL_DB.
        ConsumerStateTable routeConsumer(&observerAppDb, "ROUTE_TABLE");
        std::deque<KeyOpFieldsValuesTuple> operations;
        routeConsumer.pops(operations);

        bool sawDelete = false;
        bool sawUpdate = false;
        bool sawAdd = false;
        for (const auto &operation : operations)
        {
            if (kfvKey(operation) == staleRoute && kfvOp(operation) == DEL_COMMAND)
            {
                sawDelete = true;
            }
            if (kfvKey(operation) == changedRoute && kfvOp(operation) == SET_COMMAND &&
                hasField(kfvFieldsValues(operation), "nexthop", "198.51.100.2"))
            {
                sawUpdate = true;
            }
            if (kfvKey(operation) == newRoute && kfvOp(operation) == SET_COMMAND &&
                hasField(kfvFieldsValues(operation), "nexthop", "198.51.100.3"))
            {
                sawAdd = true;
            }
        }

        require(operations.size() == 3, "consumer did not receive exactly three route outputs");
        require(sawDelete && sawUpdate && sawAdd, "consumer missed delete, update, or add output");

        const std::string staleAfterConsume = tableField(observedRoutes, staleRoute, "nexthop");
        const std::string changedAfterConsume = tableField(observedRoutes, changedRoute, "nexthop");
        const std::string newAfterConsume = tableField(observedRoutes, newRoute, "nexthop");
        std::cout << "CONSUMER_RESULT operations=" << operations.size()
                  << " delete=" << (sawDelete ? "seen" : "missing")
                  << " update=" << (sawUpdate ? "seen" : "missing")
                  << " add=" << (sawAdd ? "seen" : "missing") << "\n";
        std::cout << "POST_CONSUME stale_route=" << staleAfterConsume
                  << " changed_route=" << changedAfterConsume
                  << " new_route=" << newAfterConsume << "\n";

        require(staleAfterConsume == "<absent>", "stale route remained after consumption");
        require(changedAfterConsume == "198.51.100.2", "changed route was not updated");
        require(newAfterConsume == "198.51.100.3", "new route was not installed");

        std::cout << "MASK_FIRED=fpmsyncd_explicit_pipeline_flush\n";
        std::cout << "PERMANENT_BAD_STATE=no\n";
        std::cout << "TEST_RESULT=PASS\n";
        return 0;
    }
    catch (const std::exception &error)
    {
        std::cerr << "TEST_RESULT=FAIL error=" << error.what() << "\n";
        return 1;
    }
}
