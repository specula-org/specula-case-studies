#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>

extern "C" {
#include "sai.h"
}

#include "Sai.h"
#include "Syncd.h"
#include "CommandLineOptions.h"
#include "MetadataLogger.h"
#include "RedisClient.h"
#include "VirtualOidTranslator.h"
#include "VendorSai.h"
#include "meta/sai_serialize.h"
#include "sairedis.h"
#include "swss/dbconnector.h"
#include "swss/logger.h"

namespace
{
using Clock = std::chrono::steady_clock;
using ObjectMap = std::unordered_map<sai_object_id_t, sai_object_id_t>;

const char* profileGetValue(sai_switch_profile_id_t, const char*)
{
    return nullptr;
}

int profileGetNextValue(sai_switch_profile_id_t, const char** variable, const char** value)
{
    if (value == nullptr)
        return 0;
    if (variable == nullptr)
        return -1;
    return -1;
}

sai_service_method_table_t serviceTable = {profileGetValue, profileGetNextValue};

void require(bool condition, const std::string& message)
{
    if (!condition)
        throw std::runtime_error(message);
}

int reserveTcpPort()
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    require(fd >= 0, "socket failed");

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    require(bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0,
            "bind for ephemeral port failed");

    socklen_t length = sizeof(address);
    require(getsockname(fd, reinterpret_cast<sockaddr*>(&address), &length) == 0,
            "getsockname failed");
    int port = static_cast<int>(ntohs(address.sin_port));
    close(fd);
    return port;
}

class IsolatedRedis
{
public:
    IsolatedRedis()
    {
        char pattern[] = "/tmp/mc4-redis-XXXXXX";
        char* made = mkdtemp(pattern);
        require(made != nullptr, "mkdtemp failed");
        directory = made;
        socketPath = directory + "/redis.sock";
        logPath = directory + "/redis.log";
        configPath = directory + "/database_config.json";
        port = reserveTcpPort();

        std::ofstream config(configPath);
        require(config.good(), "could not create database config");
        config
            << "{\n"
            << "  \"INSTANCES\": {\"redis\": {\"hostname\": \"127.0.0.1\", "
            << "\"port\": " << port << ", \"unix_socket_path\": \"" << socketPath << "\"}},\n"
            << "  \"DATABASES\": {\n"
            << "    \"APPL_DB\": {\"id\": 0, \"separator\": \":\", \"instance\": \"redis\"},\n"
            << "    \"ASIC_DB\": {\"id\": 1, \"separator\": \":\", \"instance\": \"redis\"},\n"
            << "    \"COUNTERS_DB\": {\"id\": 2, \"separator\": \":\", \"instance\": \"redis\"},\n"
            << "    \"LOGLEVEL_DB\": {\"id\": 3, \"separator\": \":\", \"instance\": \"redis\"},\n"
            << "    \"CONFIG_DB\": {\"id\": 4, \"separator\": \"|\", \"instance\": \"redis\"},\n"
            << "    \"FLEX_COUNTER_DB\": {\"id\": 5, \"separator\": \":\", \"instance\": \"redis\"},\n"
            << "    \"STATE_DB\": {\"id\": 6, \"separator\": \"|\", \"instance\": \"redis\"}\n"
            << "  },\n"
            << "  \"VERSION\": \"1.0\"\n"
            << "}\n";
        config.close();

        serverPid = fork();
        require(serverPid >= 0, "fork redis-server failed");
        if (serverPid == 0)
        {
            std::string portText = std::to_string(port);
            execlp("redis-server", "redis-server",
                   "--bind", "127.0.0.1",
                   "--port", portText.c_str(),
                   "--protected-mode", "no",
                   "--save", "",
                   "--appendonly", "no",
                   "--unixsocket", socketPath.c_str(),
                   "--unixsocketperm", "700",
                   "--logfile", logPath.c_str(),
                   static_cast<char*>(nullptr));
            _exit(127);
        }

        for (int attempt = 0; attempt != 100; ++attempt)
        {
            if (access(socketPath.c_str(), F_OK) == 0)
                return;
            int status = 0;
            if (waitpid(serverPid, &status, WNOHANG) == serverPid)
                throw std::runtime_error("redis-server exited before creating its socket");
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
        }
        throw std::runtime_error("timed out waiting for isolated redis-server");
    }

    ~IsolatedRedis()
    {
        if (serverPid > 0)
        {
            kill(serverPid, SIGTERM);
            waitpid(serverPid, nullptr, 0);
        }
        unlink(socketPath.c_str());
        unlink(configPath.c_str());
        unlink(logPath.c_str());
        rmdir(directory.c_str());
    }

    std::string directory;
    std::string socketPath;
    std::string logPath;
    std::string configPath;
    int port = 0;
    pid_t serverPid = -1;
};

std::shared_ptr<syncd::CommandLineOptions> makeSyncdOptions(const std::string& sourceRoot)
{
    auto options = std::make_shared<syncd::CommandLineOptions>();
    options->m_enableSyncMode = true;
    options->m_enableTempView = true;
    options->m_disableExitSleep = true;
    options->m_enableUnittests = false;
    options->m_enableSaiBulkSupport = true;
    options->m_startType = syncd::SAI_START_TYPE_COLD_BOOT;
    options->m_redisCommunicationMode = SAI_REDIS_COMMUNICATION_MODE_REDIS_SYNC;
    options->m_profileMapFile = sourceRoot + "/syncd/tests/brcm/testprofile.ini";
    return options;
}

pid_t startSyncd(const std::string& sourceRoot, int* readyReadFd)
{
    int ready[2];
    require(pipe(ready) == 0, "ready pipe failed");
    pid_t child = fork();
    require(child >= 0, "fork syncd failed");

    if (child == 0)
    {
        close(ready[0]);
        prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);
        try
        {
            std::string testsDir = sourceRoot + "/syncd/tests";
            if (chdir(testsDir.c_str()) != 0)
                throw std::runtime_error("chdir to syncd/tests failed");
            swss::Logger::getInstance().setMinPrio(swss::Logger::SWSS_NOTICE);
            syncd::MetadataLogger::initialize();
            auto vendorSai = std::make_shared<syncd::VendorSai>();
            auto syncdObject = std::make_shared<syncd::Syncd>(
                    vendorSai, makeSyncdOptions(sourceRoot), false);
            char marker = 'R';
            (void)!write(ready[1], &marker, 1);
            close(ready[1]);
            syncdObject->run();
            std::cout << "PRIMARY_SYNCD unexpected_run_return=yes\n";
            _exit(3);
        }
        catch (const std::exception& error)
        {
            std::cout << "PRIMARY_SYNCD uncaught=\"" << error.what() << "\"\n";
            _exit(2);
        }
    }

    close(ready[1]);
    *readyReadFd = ready[0];
    return child;
}

void waitForSyncdReady(int fd)
{
    fd_set readers;
    FD_ZERO(&readers);
    FD_SET(fd, &readers);
    timeval timeout{10, 0};
    int selected = select(fd + 1, &readers, nullptr, nullptr, &timeout);
    require(selected == 1, "timed out waiting for syncd construction");
    char marker = 0;
    require(read(fd, &marker, 1) == 1 && marker == 'R', "syncd did not signal ready");
    close(fd);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
}

class PublicSaiView
{
public:
    PublicSaiView()
    {
        sai = std::make_shared<sairedis::Sai>();
        require(sai->apiInitialize(0, &serviceTable) == SAI_STATUS_SUCCESS,
                "sairedis apiInitialize failed");
        initialized = true;

        sai_attribute_t attribute{};
        attribute.id = SAI_REDIS_SWITCH_ATTR_REDIS_COMMUNICATION_MODE;
        attribute.value.s32 = SAI_REDIS_COMMUNICATION_MODE_REDIS_SYNC;
        require(sai->set(SAI_OBJECT_TYPE_SWITCH, SAI_NULL_OBJECT_ID, &attribute) == SAI_STATUS_SUCCESS,
                "setting Redis synchronous communication failed");

        attribute.id = SAI_REDIS_SWITCH_ATTR_SYNC_OPERATION_RESPONSE_TIMEOUT;
        attribute.value.u64 = 2000;
        require(sai->set(SAI_OBJECT_TYPE_SWITCH, SAI_NULL_OBJECT_ID, &attribute) == SAI_STATUS_SUCCESS,
                "setting response timeout failed");
    }

    ~PublicSaiView()
    {
        if (initialized)
            (void)sai->apiUninitialize();
    }

    sai_object_id_t begin()
    {
        sai_attribute_t attribute{};
        attribute.id = SAI_REDIS_SWITCH_ATTR_NOTIFY_SYNCD;
        attribute.value.s32 = SAI_REDIS_NOTIFY_SYNCD_INIT_VIEW;
        require(sai->set(SAI_OBJECT_TYPE_SWITCH, SAI_NULL_OBJECT_ID, &attribute) == SAI_STATUS_SUCCESS,
                "public INIT_VIEW failed");

        attribute.id = SAI_SWITCH_ATTR_INIT_SWITCH;
        attribute.value.booldata = true;
        sai_object_id_t switchVid = SAI_NULL_OBJECT_ID;
        require(sai->create(SAI_OBJECT_TYPE_SWITCH, &switchVid, SAI_NULL_OBJECT_ID, 1, &attribute) ==
                    SAI_STATUS_SUCCESS,
                "public switch create failed");
        return switchVid;
    }

    sai_status_t apply()
    {
        sai_attribute_t attribute{};
        attribute.id = SAI_REDIS_SWITCH_ATTR_NOTIFY_SYNCD;
        attribute.value.s32 = SAI_REDIS_NOTIFY_SYNCD_APPLY_VIEW;
        return sai->set(SAI_OBJECT_TYPE_SWITCH, SAI_NULL_OBJECT_ID, &attribute);
    }

private:
    std::shared_ptr<sairedis::Sai> sai;
    bool initialized = false;
};

struct MapSnapshot
{
    ObjectMap vidToRid;
    ObjectMap ridToVid;
};

MapSnapshot readMaps()
{
    auto db = std::make_shared<swss::DBConnector>("ASIC_DB", 1000);
    auto client = std::make_shared<syncd::RedisClient>(db);
    return {client->getVidToRidMap(), client->getRidToVidMap()};
}

bool isBijective(const MapSnapshot& maps)
{
    if (maps.vidToRid.size() != maps.ridToVid.size())
        return false;
    for (const auto& entry : maps.vidToRid)
    {
        auto reverse = maps.ridToVid.find(entry.second);
        if (reverse == maps.ridToVid.end() || reverse->second != entry.first)
            return false;
    }
    return true;
}

void printMaps(const std::string& prefix, const MapSnapshot& maps)
{
    std::cout << prefix
              << " vid_to_rid=" << maps.vidToRid.size()
              << " rid_to_vid=" << maps.ridToVid.size()
              << " bijective=" << (isBijective(maps) ? "yes" : "no") << "\n";
}

std::string exerciseTranslatorDuringApply(sai_object_id_t switchVid, PublicSaiView& view,
                                          sai_status_t* applyStatus)
{
    auto db = std::make_shared<swss::DBConnector>("ASIC_DB", 1000);
    auto client = std::make_shared<syncd::RedisClient>(db);
    auto translator = std::make_shared<syncd::VirtualOidTranslator>(client, nullptr, nullptr);
    require(translator->translateVidToRid(switchVid) != SAI_NULL_OBJECT_ID,
            "pre-apply translator lookup failed");

    std::atomic<bool> stop{false};
    std::string observedError;
    std::thread observer([&]() {
        while (!stop.load())
        {
            translator->clearLocalCache();
            try
            {
                (void)translator->translateVidToRid(switchVid);
            }
            catch (const std::exception& error)
            {
                observedError = error.what();
                return;
            }
        }
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    *applyStatus = view.apply();
    stop.store(true);
    observer.join();
    return observedError;
}

bool waitForFile(const std::string& path)
{
    for (int attempt = 0; attempt != 600; ++attempt)
    {
        if (access(path.c_str(), F_OK) == 0)
            return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return false;
}

bool waitForExit(pid_t child, int timeoutMs, int* status)
{
    for (int elapsed = 0; elapsed < timeoutMs; elapsed += 25)
    {
        pid_t result = waitpid(child, status, WNOHANG);
        if (result == child)
            return true;
        if (result < 0)
            return errno == ECHILD;
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    return false;
}

pid_t startRestartConsumer(const std::string& sourceRoot)
{
    pid_t child = fork();
    require(child >= 0, "fork restart consumer failed");
    if (child == 0)
    {
        try
        {
            swss::Logger::setMinPrio(swss::Logger::SWSS_ERROR);
            swss::Logger::swssOutputNotify("MC-4 restart", "STDOUT");
            std::string testsDir = sourceRoot + "/syncd/tests";
            if (chdir(testsDir.c_str()) != 0)
                throw std::runtime_error("restart chdir failed");
            auto started = Clock::now();
            auto vendorSai = std::make_shared<syncd::VendorSai>();
            auto syncdObject = std::make_shared<syncd::Syncd>(
                    vendorSai, makeSyncdOptions(sourceRoot), false);
            syncdObject->run();
            auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                    Clock::now() - started).count();
            std::cout << "RESTART_CONSUMER syncd_run_returned=yes elapsed_ms=" << elapsed << "\n";
            _exit(0);
        }
        catch (const std::exception& error)
        {
            std::cout << "RESTART_CONSUMER uncaught=\"" << error.what() << "\"\n";
            _exit(2);
        }
    }
    return child;
}

} // namespace

int main(int argc, char** argv)
{
    setvbuf(stdout, nullptr, _IONBF, 0);
    std::cout.setf(std::ios::unitbuf);
    if (argc != 3)
    {
        std::cerr << "usage: " << argv[0] << " SOURCE_ROOT GO_FILE\n";
        return 64;
    }

    const std::string sourceRoot = argv[1];
    const std::string goFile = argv[2];
    pid_t primarySyncd = -1;

    try
    {
        IsolatedRedis redis;
        swss::SonicDBConfig::initialize(redis.configPath);
        std::cout << "ARTIFACT source_root=" << sourceRoot << " isolated_redis=yes\n";

        int readyFd = -1;
        primarySyncd = startSyncd(sourceRoot, &readyFd);
        waitForSyncdReady(readyFd);
        std::cout << "PUBLIC_PATH primary_syncd_pid=" << primarySyncd << "\n";

        sai_object_id_t switchVid = SAI_NULL_OBJECT_ID;
        {
            PublicSaiView firstView;
            switchVid = firstView.begin();
            sai_status_t status = firstView.apply();
            require(status == SAI_STATUS_SUCCESS, "first public APPLY_VIEW failed");
            std::cout << "LEVEL0 initial_apply=success switch_vid="
                      << sai_serialize_object_id(switchVid) << "\n";
        }

        {
            PublicSaiView secondView;
            sai_object_id_t secondSwitchVid = secondView.begin();
            require(secondSwitchVid == switchVid, "switch VID was not deterministic across views");
            sai_status_t status = SAI_STATUS_FAILURE;
            std::string observed = exerciseTranslatorDuringApply(switchVid, secondView, &status);
            require(status == SAI_STATUS_SUCCESS, "second public APPLY_VIEW failed");
            MapSnapshot finalMaps = readMaps();
            printMaps("LEVEL0 final", finalMaps);
            require(isBijective(finalMaps) && !finalMaps.vidToRid.empty(),
                    "successful APPLY_VIEW did not finish with reciprocal maps");
            std::cout << "LEVEL0 concurrent_translator="
                      << (observed.empty() ? "no_error_observed" : "threw")
                      << (observed.empty() ? "" : " message=\"")
                      << observed
                      << (observed.empty() ? "" : "\"") << "\n";
            std::cout << "LEVEL0 downstream_repopulation=masked_transient_cut\n";
        }

        PublicSaiView thirdView;
        sai_object_id_t thirdSwitchVid = thirdView.begin();
        require(thirdSwitchVid == switchVid, "switch VID changed before crash cut");
        std::cout << "ATTACH_READY syncd_pid=" << primarySyncd
                  << " redis_socket=" << redis.socketPath
                  << " go_file=" << goFile << "\n";
        require(waitForFile(goFile), "debugger did not arm the crash cut in time");

        sai_status_t crashApplyStatus = SAI_STATUS_SUCCESS;
        std::string applyException;
        try
        {
            crashApplyStatus = thirdView.apply();
        }
        catch (const std::exception& error)
        {
            applyException = error.what();
        }

        int primaryStatus = 0;
        require(waitForExit(primarySyncd, 5000, &primaryStatus),
                "debugger did not terminate primary syncd at the cut");
        primarySyncd = -1;
        std::cout << "LEVEL1 public_apply_status=" << sai_serialize_status(crashApplyStatus)
                  << " exception=\"" << applyException << "\"\n";

        MapSnapshot cut = readMaps();
        printMaps("LEVEL1 persisted_cut", cut);
        require(cut.vidToRid.empty(), "VIDTORID was not empty at the requested source cut");
        require(!cut.ridToVid.empty(), "RIDTOVID did not retain the old authority map");
        require(!isBijective(cut), "source cut unexpectedly remained bijective");

        std::this_thread::sleep_for(std::chrono::milliseconds(1000));
        MapSnapshot afterWait = readMaps();
        printMaps("LEVEL1 after_1000ms", afterWait);
        require(afterWait.vidToRid.size() == cut.vidToRid.size() &&
                    afterWait.ridToVid.size() == cut.ridToVid.size() &&
                    !isBijective(afterWait),
                "a downstream mechanism repaired the cut before restart");

        auto consumerDb = std::make_shared<swss::DBConnector>("ASIC_DB", 1000);
        auto consumerClient = std::make_shared<syncd::RedisClient>(consumerDb);
        syncd::VirtualOidTranslator consumer(consumerClient, nullptr, nullptr);
        std::string consumerError;
        try
        {
            (void)consumer.translateVidToRid(switchVid);
        }
        catch (const std::exception& error)
        {
            consumerError = error.what();
        }
        std::cout << "REAL_CONSUMER VirtualOidTranslator.cpp:361 result="
                  << (consumerError.empty() ? "success" : "threw")
                  << " message=\"" << consumerError << "\"\n";
        require(consumerError.find("unable to get RID for VID") != std::string::npos,
                "production translator did not observe the missing forward map");
        std::cout << "REAL_CALLER Syncd.cpp:6257 warm_restart_uses_same_translation=yes\n";

        pid_t restartConsumer = startRestartConsumer(sourceRoot);
        int restartStatus = 0;
        bool restartReturned = waitForExit(restartConsumer, 5000, &restartStatus);
        if (!restartReturned)
        {
            kill(restartConsumer, SIGKILL);
            waitpid(restartConsumer, &restartStatus, 0);
        }
        std::cout << "REAL_RESTART Syncd.cpp:6041 init_failure_path_returned="
                  << (restartReturned ? "yes" : "no")
                  << " exit_code="
                  << (WIFEXITED(restartStatus) ? WEXITSTATUS(restartStatus) : -1) << "\n";
        require(restartReturned && WIFEXITED(restartStatus) && WEXITSTATUS(restartStatus) == 0,
                "restart syncd did not take its expected init-failure exit path");

        MapSnapshot afterRestart = readMaps();
        printMaps("LEVEL1 after_restart", afterRestart);
        require(!isBijective(afterRestart) && afterRestart.vidToRid.empty() &&
                    !afterRestart.ridToVid.empty(),
                "restart unexpectedly repaired the authority maps");

        std::cout << "RESULT permanent_nonreciprocal_state=yes restart_validation_or_repair=no\n";
        std::cout << "TEST_PASS MC-4\n";
        return 0;
    }
    catch (const std::exception& error)
    {
        if (primarySyncd > 0)
        {
            kill(primarySyncd, SIGKILL);
            waitpid(primarySyncd, nullptr, 0);
        }
        std::cerr << "TEST_FAIL " << error.what() << "\n";
        return 1;
    }
}
