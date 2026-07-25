#include <iostream>
#include <fstream>
#include <nlohmann/json.hpp>
#include <chrono>
#include <vector>
#include <string>

using json = nlohmann::json;

// Simple test harness that generates synthetic traces matching the spec
// This demonstrates the trace format that would be collected from instrumented code

class TraceGenerator {
private:
    std::ofstream trace_file_;
    uint64_t event_counter_{0};

public:
    TraceGenerator(const std::string& trace_file_path) {
        trace_file_.open(trace_file_path, std::ios::app);
        if (!trace_file_.is_open()) {
            std::cerr << "Failed to open trace file: " << trace_file_path << std::endl;
        }
    }

    ~TraceGenerator() {
        if (trace_file_.is_open()) {
            trace_file_.flush();
            trace_file_.close();
        }
    }

    uint64_t get_timestamp_ms() {
        auto now = std::chrono::system_clock::now();
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            now.time_since_epoch()).count();
    }

    void emit_event(const std::string& event_name,
                    const std::string& node_id,
                    const json& fields) {
        if (!trace_file_.is_open()) return;

        json event = {
            {"tag", "trace"},
            {"ts", get_timestamp_ms()},
            {"event", {
                {"name", event_name},
                {"nid", node_id}
            }}
        };

        for (auto& [key, value] : fields.items()) {
            event["event"][key] = value;
        }

        trace_file_ << event.dump() << std::endl;
        trace_file_.flush();
    }
};

// Scenario 1: Normal reconfig operation
void scenario_normal_reconfig(const std::string& trace_file) {
    TraceGenerator gen(trace_file);

    std::cout << "Generating normal reconfig scenario..." << std::endl;

    // ReConfigInitiate: Start reconfig to version 2
    gen.emit_event("ReConfigInitiate", "s1", {
        {"newVersion", 2},
        {"newTerm", 0}
    });

    // QuorumStart: Begin quorum check
    gen.emit_event("QuorumStart", "s1", {
        {"configState", "kConfigReconfiguring"}
    });

    // QuorumResponse from s2
    gen.emit_event("QuorumResponse", "s1", {
        {"voter", "s2"},
        {"votersResponded", 2}
    });

    // QuorumResponse from s3
    gen.emit_event("QuorumResponse", "s1", {
        {"voter", "s3"},
        {"votersResponded", 3}
    });

    // ReConfigPersist: Persist to disk
    gen.emit_event("ReConfigPersist", "s1", {
        {"newVersion", 2},
        {"newTerm", 0}
    });

    // JournalFlush: Durability guaranteed
    gen.emit_event("JournalFlush", "s1", {
        {"persistedVersion", 2},
        {"persistedTerm", 0},
        {"inMemoryVersion", 2},
        {"inMemoryTerm", 0}
    });

    // ReConfigInstall: Install in-memory
    gen.emit_event("ReConfigInstall", "s1", {
        {"newVersion", 2},
        {"newTerm", 0}
    });

    // Heartbeat: Send new config to other nodes
    gen.emit_event("Heartbeat", "s1", {
        {"dest", "s2"},
        {"inMemoryVersion", 2},
        {"inMemoryTerm", 0}
    });

    std::cout << "Normal reconfig scenario generated" << std::endl;
}

// Scenario 2: Reconfig with quorum timeout
void scenario_quorum_timeout(const std::string& trace_file) {
    TraceGenerator gen(trace_file);

    std::cout << "Generating quorum timeout scenario..." << std::endl;

    // ReConfigInitiate
    gen.emit_event("ReConfigInitiate", "s2", {
        {"newVersion", 2},
        {"newTerm", 1}
    });

    // QuorumStart
    gen.emit_event("QuorumStart", "s2", {
        {"configState", "kConfigReconfiguring"}
    });

    // Only one response arrives
    gen.emit_event("QuorumResponse", "s2", {
        {"voter", "s1"},
        {"votersResponded", 2}
    });

    // Quorum timeout: not enough responses
    gen.emit_event("QuorumTimeout", "s2", {
        {"configState", "kConfigReconfiguring"}
    });

    std::cout << "Quorum timeout scenario generated" << std::endl;
}

// Scenario 3: Crash recovery
void scenario_crash_recovery(const std::string& trace_file) {
    TraceGenerator gen(trace_file);

    std::cout << "Generating crash recovery scenario..." << std::endl;

    // ReConfigInitiate
    gen.emit_event("ReConfigInitiate", "s3", {
        {"newVersion", 3},
        {"newTerm", 2}
    });

    // QuorumStart
    gen.emit_event("QuorumStart", "s3", {
        {"configState", "kConfigReconfiguring"}
    });

    // QuorumResponse
    gen.emit_event("QuorumResponse", "s3", {
        {"voter", "s1"},
        {"votersResponded", 2}
    });

    gen.emit_event("QuorumResponse", "s3", {
        {"voter", "s2"},
        {"votersResponded", 3}
    });

    // ReConfigPersist
    gen.emit_event("ReConfigPersist", "s3", {
        {"newVersion", 3},
        {"newTerm", 2}
    });

    // Journal flush
    gen.emit_event("JournalFlush", "s3", {
        {"persistedVersion", 3},
        {"persistedTerm", 2},
        {"inMemoryVersion", 3},
        {"inMemoryTerm", 2}
    });

    // Crash recovery: revert in-memory to persisted state
    gen.emit_event("CrashRecovery", "s3", {
        {"persistedVersion", 3},
        {"persistedTerm", 2},
        {"inMemoryVersion", 3},
        {"inMemoryTerm", 2}
    });

    std::cout << "Crash recovery scenario generated" << std::endl;
}

// Scenario 4: Force reconfig
void scenario_force_reconfig(const std::string& trace_file) {
    TraceGenerator gen(trace_file);

    std::cout << "Generating force reconfig scenario..." << std::endl;

    // ReConfigInitiate with force reconfig (term = -1)
    gen.emit_event("ReConfigInitiate", "s1", {
        {"newVersion", 10001},
        {"newTerm", -1}
    });

    // QuorumStart
    gen.emit_event("QuorumStart", "s1", {
        {"configState", "kConfigReconfiguring"}
    });

    // QuorumResponse (quorum check may be skipped for force reconfig)
    gen.emit_event("QuorumResponse", "s1", {
        {"voter", "s2"},
        {"votersResponded", 2}
    });

    // ReConfigPersist
    gen.emit_event("ReConfigPersist", "s1", {
        {"newVersion", 10001},
        {"newTerm", -1}
    });

    // JournalFlush
    gen.emit_event("JournalFlush", "s1", {
        {"persistedVersion", 10001},
        {"persistedTerm", -1},
        {"inMemoryVersion", 10001},
        {"inMemoryTerm", -1}
    });

    // ReConfigInstall
    gen.emit_event("ReConfigInstall", "s1", {
        {"newVersion", 10001},
        {"newTerm", -1}
    });

    std::cout << "Force reconfig scenario generated" << std::endl;
}

int main() {
    std::string traces_dir = "../traces";

    // Create traces directory if it doesn't exist
    std::string mkdir_cmd = "mkdir -p " + traces_dir;
    system(mkdir_cmd.c_str());

    scenario_normal_reconfig(traces_dir + "/normal_reconfig.ndjson");
    scenario_quorum_timeout(traces_dir + "/quorum_timeout.ndjson");
    scenario_crash_recovery(traces_dir + "/crash_recovery.ndjson");
    scenario_force_reconfig(traces_dir + "/force_reconfig.ndjson");

    std::cout << "\nAll scenarios generated successfully!" << std::endl;
    return 0;
}
