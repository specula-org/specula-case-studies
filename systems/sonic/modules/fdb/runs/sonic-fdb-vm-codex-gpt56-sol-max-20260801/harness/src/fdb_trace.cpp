#include "fdb_trace.h"

#ifdef FDB_TLA_TRACE

#include <chrono>
#include <cstdlib>
#include <fstream>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace fdb_trace
{
namespace
{

using json = nlohmann::json;

struct Entry
{
    bool present = false;
    int gen = 0;
    std::string dest = "none";
    int bpGen = 0;
    std::string kind = "dynamic";
};

struct Transaction
{
    std::string phase = "idle";
    std::string op = "none";
    std::string key = "none";
    int eventGen = 0;
    std::string newDest = "none";
    int newBpGen = 0;
    std::string entryKind = "dynamic";
    bool oldPresent = false;
    int oldGen = 0;
    std::string oldDest = "none";
    int oldBpGen = 0;
    int ackEpoch = 0;
    int markedEpoch = 0;
};

struct FlushAudit
{
    bool valid = false;
    int ackEpoch = 0;
    int markedEpoch = 0;
    int ackGen = 0;
    int removedGen = 0;
    bool kindMatched = true;
    bool scopeMatched = true;
};

struct DeletionAudit
{
    bool valid = false;
    std::string cause = "none";
    int eventGen = 0;
    int removedGen = 0;
};

struct PendingEvent
{
    std::string id;
    std::string op;
    int gen = 0;
    std::string dest = "none";
    int bpGen = 0;
    std::string entryKind = "dynamic";
};

struct FlushState
{
    std::string scope = "all";
    std::string port = "none";
    std::string kind = "dynamic";
    std::string path = "none";
    std::string status = "unused";
    Entry snapshot;
    bool ackCreated = false;
};

json entryJson(const Entry &entry)
{
    return {
        {"present", entry.present},
        {"gen", entry.gen},
        {"dest", entry.dest},
        {"bpGen", entry.bpGen},
        {"kind", entry.kind},
    };
}

json transactionJson(const Transaction &txn)
{
    return {
        {"phase", txn.phase},
        {"op", txn.op},
        {"key", txn.key},
        {"eventGen", txn.eventGen},
        {"newDest", txn.newDest},
        {"newBpGen", txn.newBpGen},
        {"entryKind", txn.entryKind},
        {"oldPresent", txn.oldPresent},
        {"oldGen", txn.oldGen},
        {"oldDest", txn.oldDest},
        {"oldBpGen", txn.oldBpGen},
        {"ackEpoch", txn.ackEpoch},
        {"markedEpoch", txn.markedEpoch},
    };
}

json flushAuditJson(const FlushAudit &audit)
{
    return {
        {"valid", audit.valid},
        {"ackEpoch", audit.ackEpoch},
        {"markedEpoch", audit.markedEpoch},
        {"ackGen", audit.ackGen},
        {"removedGen", audit.removedGen},
        {"kindMatched", audit.kindMatched},
        {"scopeMatched", audit.scopeMatched},
    };
}

json deletionAuditJson(const DeletionAudit &audit)
{
    return {
        {"valid", audit.valid},
        {"cause", audit.cause},
        {"eventGen", audit.eventGen},
        {"removedGen", audit.removedGen},
    };
}

class Collector
{
  public:
    static Collector &instance()
    {
        static Collector collector;
        return collector;
    }

    void receive(NotificationKind kind,
                 const std::string &realKey,
                 const std::string &realPort)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (!isEnabled() || !selectKey(realKey) || m_nextEventId > 3)
        {
            return;
        }

        const std::string port = mapPort(realPort);
        if (port == "none")
        {
            return;
        }

        PendingEvent pending;
        pending.id = "ev" + std::to_string(m_nextEventId++);
        pending.entryKind = "dynamic";

        std::string eventName;
        if (kind == NotificationKind::Learn)
        {
            if (m_kernel.present)
            {
                return;
            }
            eventName = "SaiLearnEvent";
            pending.op = "learn";
            advanceHardware(port, pending);
        }
        else if (kind == NotificationKind::Move)
        {
            eventName = "SaiMoveEvent";
            pending.op = "move";
            advanceHardware(port, pending);
        }
        else
        {
            if (!m_asic.present)
            {
                return;
            }
            eventName = "SaiAgeEvent";
            pending.op = "aged";
            pending.gen = m_asic.gen;
            pending.dest = m_asic.dest;
            pending.bpGen = m_asic.bpGen;
            pending.entryKind = m_asic.kind;
            m_kernel = Entry{};
            m_asic = Entry{};
        }

        m_events.push_back(pending);
        json args = {
            {"key", "k1"},
            {"eventId", pending.id},
        };
        if (kind != NotificationKind::Aged)
        {
            args["port"] = port;
        }
        emit(eventName, args, true, false);
    }

    void start(const std::string &realKey)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (!isSelected(realKey) || m_txn.phase != "idle" || m_events.empty())
        {
            return;
        }

        const PendingEvent pending = m_events.front();
        if (pending.op == "aged" && !m_cache.present)
        {
            return;
        }
        m_events.erase(m_events.begin());

        m_txn.phase = "counter";
        m_txn.op = pending.op;
        m_txn.key = "k1";
        m_txn.eventGen = pending.gen;
        m_txn.newDest = pending.dest;
        m_txn.newBpGen = pending.bpGen;
        m_txn.entryKind = pending.entryKind;
        m_txn.oldPresent = m_cache.present;
        m_txn.oldGen = m_cache.gen;
        m_txn.oldDest = m_cache.dest;
        m_txn.oldBpGen = m_cache.bpGen;
        m_txn.ackEpoch = 0;
        m_txn.markedEpoch = m_pendingEpoch;

        emit("FdbOrchUpdateStart",
             {{"key", "k1"}, {"eventId", pending.id}}, true, false);
    }

    void ignore(const std::string &realKey)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (!isSelected(realKey) || m_txn.phase != "idle" || m_events.empty() ||
            m_events.front().op != "aged" || m_cache.present)
        {
            return;
        }
        const PendingEvent pending = m_events.front();
        m_events.erase(m_events.begin());
        emit("FdbOrchIgnoreAgedEvent",
             {{"key", "k1"}, {"eventId", pending.id}}, true, false);
    }

    void counters(const std::string &realKey)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (!isSelected(realKey) || m_txn.phase != "counter")
        {
            return;
        }

        const bool isAdd = m_txn.op == "learn" || m_txn.op == "move" ||
                           m_txn.op == "replay" || m_txn.op == "nhgFdb";
        if (isAdd)
        {
            if (!m_txn.oldPresent)
            {
                ++m_portCounts[m_txn.newDest];
                ++m_vlanCount;
            }
            else if (m_txn.oldDest != m_txn.newDest)
            {
                --m_portCounts[m_txn.oldDest];
                ++m_portCounts[m_txn.newDest];
            }
        }
        else if ((m_txn.op == "aged" || m_txn.op == "flush") &&
                 m_txn.oldPresent)
        {
            --m_portCounts[m_txn.oldDest];
            --m_vlanCount;
        }
        m_txn.phase = "store";
        emit("FdbOrchUpdateCounters", {{"key", "k1"}}, true, false);
    }

    void store(const std::string &realKey)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (!isSelected(realKey) || m_txn.phase != "store")
        {
            return;
        }

        const bool isAdd = m_txn.op == "learn" || m_txn.op == "move" ||
                           m_txn.op == "replay" || m_txn.op == "nhgFdb";
        if (isAdd)
        {
            Entry entry;
            entry.present = true;
            entry.gen = m_txn.eventGen;
            entry.dest = m_txn.newDest;
            entry.bpGen = m_txn.newBpGen;
            entry.kind = m_txn.entryKind;
            m_cache = entry;
            m_stateDb = entry;
            if (!m_txn.oldPresent)
            {
                ++m_crmCount;
            }
        }
        else
        {
            m_cache = Entry{};
            m_stateDb = Entry{};
            if (m_txn.oldPresent)
            {
                --m_crmCount;
                m_lastDeletion.valid = true;
                m_lastDeletion.cause = m_txn.op;
                m_lastDeletion.eventGen = m_txn.eventGen;
                m_lastDeletion.removedGen = m_txn.oldGen;
            }
        }
        m_pendingEpoch = 0;
        m_txn.phase = "observer";
        emit("FdbOrchStoreFdbEntryState", {{"key", "k1"}}, true, false);
    }

    void observers(const std::string &realKey)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (!isSelected(realKey) || m_txn.phase != "observer")
        {
            return;
        }
        m_observer = m_cache;
        m_txn = Transaction{};
        emit("FdbOrchNotifyObservers", {{"key", "k1"}}, true, false);
    }

    std::uint64_t requestFlush(bool byVlan,
                               const std::string &scope,
                               const std::string &realPort)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (!isEnabled() || m_flushEpoch >= 2)
        {
            return 0;
        }

        const std::uint64_t epoch = ++m_flushEpoch;
        FlushState state;
        state.scope = byVlan ? "vlan" : scope;
        state.port = mapPort(realPort);
        if (state.port == "none")
        {
            state.port = "p1";
        }
        state.kind = "dynamic";
        state.path = byVlan ? "flushFdbByVlan" : "flushFDBEntries";
        state.status = "requested";
        state.snapshot = m_cache;
        m_flushes[epoch] = state;

        const std::string name = byVlan ? "FdbOrchFlushFdbByVlanRequest"
                                        : "FdbOrchFlushFDBEntriesRequest";
        emit(name,
             {{"key", "k1"},
              {"port", state.port},
              {"scope", state.scope},
              {"epoch", epoch}},
             false, true, epoch);
        return epoch;
    }

    void finishFlush(std::uint64_t epoch, bool success)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        const auto found = m_flushes.find(epoch);
        if (!isEnabled() || epoch == 0 || found == m_flushes.end() ||
            found->second.status != "requested")
        {
            return;
        }

        FlushState &state = found->second;
        if (success)
        {
            if (m_asic.present && m_asic.kind == state.kind &&
                scopeMatches(state, m_asic))
            {
                m_asic = Entry{};
            }
            if (state.path == "flushFDBEntries" && m_cache.present &&
                scopeMatches(state, m_cache))
            {
                m_pendingEpoch = static_cast<int>(epoch);
            }
            state.status = "asicDone";
        }
        else
        {
            state.status = "failed";
        }

        emit(success ? "SaiFlushSuccess" : "SaiFlushFailure",
             {{"key", "k1"}, {"epoch", epoch}}, false, true, epoch);
    }

  private:
    Collector()
    {
        const char *path = std::getenv("FDB_TLA_TRACE_FILE");
        if (path != nullptr)
        {
            m_path = path;
        }
        m_portCounts["p1"] = 0;
        m_portCounts["p2"] = 0;
    }

    bool isEnabled() const
    {
        return !m_path.empty();
    }

    bool selectKey(const std::string &realKey)
    {
        if (realKey.empty())
        {
            return false;
        }
        if (m_realKey.empty())
        {
            m_realKey = realKey;
        }
        return m_realKey == realKey;
    }

    bool isSelected(const std::string &realKey) const
    {
        return isEnabled() && !m_realKey.empty() && m_realKey == realKey;
    }

    std::string mapPort(const std::string &realPort)
    {
        if (realPort.empty())
        {
            return "p1";
        }
        const auto found = m_ports.find(realPort);
        if (found != m_ports.end())
        {
            return found->second;
        }
        if (m_ports.size() >= 2)
        {
            return "none";
        }
        const std::string mapped = m_ports.empty() ? "p1" : "p2";
        m_ports[realPort] = mapped;
        return mapped;
    }

    void advanceHardware(const std::string &port, PendingEvent &pending)
    {
        ++m_generation;
        Entry entry;
        entry.present = true;
        entry.gen = m_generation;
        entry.dest = port;
        entry.bpGen = 1;
        entry.kind = "dynamic";
        m_kernel = entry;
        m_asic = entry;
        pending.gen = entry.gen;
        pending.dest = entry.dest;
        pending.bpGen = entry.bpGen;
    }

    bool scopeMatches(const FlushState &flush, const Entry &entry) const
    {
        return flush.scope == "all" || flush.scope == "vlan" ||
               ((flush.scope == "port" || flush.scope == "portvlan") &&
                entry.dest == flush.port);
    }

    json fdbStateJson() const
    {
        return {
            {"generation", m_generation},
            {"kernel", entryJson(m_kernel)},
            {"cache", entryJson(m_cache)},
            {"stateDb", entryJson(m_stateDb)},
            {"asic", entryJson(m_asic)},
            {"observer", entryJson(m_observer)},
            {"txn", transactionJson(m_txn)},
            {"eventQueueSize", m_events.size()},
            {"crmCount", m_crmCount},
            {"portCounts", {{"p1", m_portCounts.at("p1")},
                             {"p2", m_portCounts.at("p2")}}},
            {"vlanCount", m_vlanCount},
            {"pendingEpoch", m_pendingEpoch},
            {"lastFlushCleanup", flushAuditJson(m_lastFlushCleanup)},
            {"lastDeletion", deletionAuditJson(m_lastDeletion)},
            {"fdbFailure", false},
            {"fdbRetry", false},
            {"fdbCompensated", false},
        };
    }

    json flushStateJson(std::uint64_t epoch) const
    {
        const FlushState &state = m_flushes.at(epoch);
        return {
            {"flushEpoch", m_flushEpoch},
            {"scope", state.scope},
            {"port", state.port},
            {"kind", state.kind},
            {"path", state.path},
            {"status", state.status},
            {"snapshot", entryJson(state.snapshot)},
            {"ackCreated", state.ackCreated},
            {"ackQueueSize", 0},
            {"pendingEpoch", m_pendingEpoch},
            {"asic", entryJson(m_asic)},
            {"lastFlushCleanup", flushAuditJson(m_lastFlushCleanup)},
            {"lastDeletion", deletionAuditJson(m_lastDeletion)},
        };
    }

    void emit(const std::string &name,
              json args,
              bool includeFdb,
              bool includeFlush,
              std::uint64_t epoch = 0)
    {
        if (!ensureOpen())
        {
            return;
        }
        args["name"] = name;
        if (includeFdb)
        {
            args["state"]["fdb"] = fdbStateJson();
        }
        if (includeFlush)
        {
            args["state"]["flush"] = flushStateJson(epoch);
        }

        const auto now = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        json line = {
            {"tag", "trace"},
            {"seq", ++m_sequence},
            {"timestamp_ns", now},
            {"process", "orchagent"},
            {"event", std::move(args)},
        };
        m_output << line.dump() << '\n';
        m_output.flush();
    }

    bool ensureOpen()
    {
        if (m_output.is_open())
        {
            return true;
        }
        m_output.open(m_path, std::ios::out | std::ios::trunc);
        return m_output.good();
    }

    std::mutex m_mutex;
    std::string m_path;
    std::ofstream m_output;
    std::uint64_t m_sequence = 0;
    std::string m_realKey;
    std::map<std::string, std::string> m_ports;

    int m_generation = 0;
    Entry m_kernel;
    Entry m_cache;
    Entry m_stateDb;
    Entry m_asic;
    Entry m_observer;
    Transaction m_txn;
    std::vector<PendingEvent> m_events;
    int m_nextEventId = 1;
    int m_crmCount = 0;
    std::map<std::string, int> m_portCounts;
    int m_vlanCount = 0;
    int m_pendingEpoch = 0;
    FlushAudit m_lastFlushCleanup;
    DeletionAudit m_lastDeletion;

    std::uint64_t m_flushEpoch = 0;
    std::map<std::uint64_t, FlushState> m_flushes;
};

} // namespace

void receiveNotification(NotificationKind kind,
                         const std::string &realKey,
                         const std::string &realPort) noexcept
{
    try
    {
        Collector::instance().receive(kind, realKey, realPort);
    }
    catch (...)
    {
    }
}

void updateStart(const std::string &realKey) noexcept
{
    try
    {
        Collector::instance().start(realKey);
    }
    catch (...)
    {
    }
}

void ignoreAged(const std::string &realKey) noexcept
{
    try
    {
        Collector::instance().ignore(realKey);
    }
    catch (...)
    {
    }
}

void updateCounters(const std::string &realKey) noexcept
{
    try
    {
        Collector::instance().counters(realKey);
    }
    catch (...)
    {
    }
}

void storeFdbEntryState(const std::string &realKey) noexcept
{
    try
    {
        Collector::instance().store(realKey);
    }
    catch (...)
    {
    }
}

void notifyObservers(const std::string &realKey) noexcept
{
    try
    {
        Collector::instance().observers(realKey);
    }
    catch (...)
    {
    }
}

std::uint64_t flushRequest(bool byVlan,
                           const std::string &scope,
                           const std::string &realPort) noexcept
{
    try
    {
        return Collector::instance().requestFlush(byVlan, scope, realPort);
    }
    catch (...)
    {
        return 0;
    }
}

void flushResult(std::uint64_t epoch, bool success) noexcept
{
    try
    {
        Collector::instance().finishFlush(epoch, success);
    }
    catch (...)
    {
    }
}

} // namespace fdb_trace

#endif
