#pragma once

#include <iostream>
#include <fstream>
#include <mutex>
#include <string>
#include <map>
#include <chrono>
#include <nlohmann/json.hpp>

namespace mongo::tla_trace {

using json = nlohmann::json;

class TraceWriter {
private:
    std::ofstream trace_file_;
    std::mutex trace_mutex_;
    std::map<std::string, std::string> server_id_map_;
    int next_server_id_{0};
    bool enabled_{true};

public:
    TraceWriter() = default;

    ~TraceWriter() {
        if (trace_file_.is_open()) {
            trace_file_.flush();
            trace_file_.close();
        }
    }

    void init(const std::string& trace_file_path) {
        std::lock_guard<std::mutex> lock(trace_mutex_);
        if (!trace_file_.is_open()) {
            trace_file_.open(trace_file_path, std::ios::app);
            if (!trace_file_.is_open()) {
                std::cerr << "Failed to open trace file: " << trace_file_path << std::endl;
                enabled_ = false;
            }
        }
    }

    std::string normalize_server_id(const std::string& impl_server_id) {
        std::lock_guard<std::mutex> lock(trace_mutex_);
        auto it = server_id_map_.find(impl_server_id);
        if (it == server_id_map_.end()) {
            std::string tla_id = "s" + std::to_string(++next_server_id_);
            server_id_map_[impl_server_id] = tla_id;
            return tla_id;
        }
        return it->second;
    }

    uint64_t get_timestamp_ms() {
        auto now = std::chrono::system_clock::now();
        auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(
            now.time_since_epoch()).count();
        return millis;
    }

    void emit_event(const std::string& event_name,
                    const std::string& node_id,
                    const json& event_fields) {
        if (!enabled_) return;

        std::lock_guard<std::mutex> lock(trace_mutex_);
        if (!trace_file_.is_open()) return;

        json event = {
            {"tag", "trace"},
            {"ts", get_timestamp_ms()},
            {"event", {
                {"name", event_name},
                {"nid", node_id}
            }}
        };

        for (auto& [key, value] : event_fields.items()) {
            event["event"][key] = value;
        }

        trace_file_ << event.dump() << std::endl;
        trace_file_.flush();
    }

    void flush() {
        std::lock_guard<std::mutex> lock(trace_mutex_);
        if (trace_file_.is_open()) {
            trace_file_.flush();
        }
    }
};

// Global trace writer instance
static TraceWriter g_trace_writer;

inline void init_trace(const std::string& trace_file_path) {
    g_trace_writer.init(trace_file_path);
}

inline void emit_compare_config(const std::string& node_id,
                               int in_memory_version,
                               int in_memory_term,
                               int topcoord_term) {
    json fields = {
        {"inMemoryVersion", in_memory_version},
        {"inMemoryTerm", in_memory_term},
        {"topCoordTerm", topcoord_term}
    };
    g_trace_writer.emit_event("CompareConfig", node_id, fields);
}

inline void emit_reconfig_initiate(const std::string& node_id,
                                   int new_version,
                                   int new_term) {
    json fields = {
        {"newVersion", new_version},
        {"newTerm", new_term},
        {"configState", "kConfigReconfiguring"}
    };
    g_trace_writer.emit_event("ReConfigInitiate", node_id, fields);
}

inline void emit_quorum_start(const std::string& node_id) {
    json fields = {
        {"configState", "kConfigReconfiguring"}
    };
    g_trace_writer.emit_event("QuorumStart", node_id, fields);
}

inline void emit_quorum_response(const std::string& node_id,
                                const std::string& voter,
                                int num_voters_responded) {
    json fields = {
        {"voter", voter},
        {"votersResponded", num_voters_responded}
    };
    g_trace_writer.emit_event("QuorumResponse", node_id, fields);
}

inline void emit_quorum_timeout(const std::string& node_id) {
    json fields = {
        {"configState", "kConfigReconfiguring"}
    };
    g_trace_writer.emit_event("QuorumTimeout", node_id, fields);
}

inline void emit_reconfig_persist(const std::string& node_id,
                                  int new_version,
                                  int new_term) {
    json fields = {
        {"newVersion", new_version},
        {"newTerm", new_term},
        {"configState", "kConfigReconfiguring"}
    };
    g_trace_writer.emit_event("ReConfigPersist", node_id, fields);
}

inline void emit_journal_flush(const std::string& node_id,
                              int persisted_version,
                              int persisted_term,
                              int in_memory_version,
                              int in_memory_term) {
    json fields = {
        {"persistedVersion", persisted_version},
        {"persistedTerm", persisted_term},
        {"inMemoryVersion", in_memory_version},
        {"inMemoryTerm", in_memory_term}
    };
    g_trace_writer.emit_event("JournalFlush", node_id, fields);
}

inline void emit_reconfig_install(const std::string& node_id,
                                  int new_version,
                                  int new_term) {
    json fields = {
        {"newVersion", new_version},
        {"newTerm", new_term},
        {"configState", "kConfigSteady"}
    };
    g_trace_writer.emit_event("ReConfigInstall", node_id, fields);
}

inline void emit_crash_recovery(const std::string& node_id,
                               int persisted_version,
                               int persisted_term,
                               int in_memory_version,
                               int in_memory_term) {
    json fields = {
        {"persistedVersion", persisted_version},
        {"persistedTerm", persisted_term},
        {"inMemoryVersion", in_memory_version},
        {"inMemoryTerm", in_memory_term}
    };
    g_trace_writer.emit_event("CrashRecovery", node_id, fields);
}

inline void emit_heartbeat(const std::string& node_id,
                          const std::string& dest,
                          int in_memory_version,
                          int in_memory_term) {
    json fields = {
        {"dest", dest},
        {"inMemoryVersion", in_memory_version},
        {"inMemoryTerm", in_memory_term}
    };
    g_trace_writer.emit_event("Heartbeat", node_id, fields);
}

inline void emit_advance_commit(const std::string& node_id,
                               int optime,
                               int in_memory_version,
                               int in_memory_term) {
    json fields = {
        {"optime", optime},
        {"inMemoryVersion", in_memory_version},
        {"inMemoryTerm", in_memory_term}
    };
    g_trace_writer.emit_event("AdvanceCommit", node_id, fields);
}

inline void flush_trace() {
    g_trace_writer.flush();
}

} // namespace mongo::tla_trace
