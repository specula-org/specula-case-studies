/************************************************************************
 * TLA+ Trace Emitter for nuraft
 *
 * Header-only, thread-safe NDJSON trace emission for TLA+ trace validation.
 * Guarded by NURAFT_TLA_TRACE compile flag.
 * Trace file path set via NURAFT_TRACE_FILE environment variable.
 ************************************************************************/

#ifndef NURAFT_TLA_TRACE_HXX
#define NURAFT_TLA_TRACE_HXX

#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <mutex>
#include <string>
#include <cstdint>

namespace nuraft {
namespace tla_trace {

inline const char* role_to_str(int role) {
    // nuraft srv_role enum: follower=1, candidate=2, leader=3
    switch (role) {
        case 1: return "follower";
        case 2: return "candidate";
        case 3: return "leader";
        default: return "unknown";
    }
}

inline std::string server_name(int id) {
    return "s" + std::to_string(id);
}

inline int64_t now_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

class TraceWriter {
public:
    static TraceWriter& instance() {
        static TraceWriter inst;
        return inst;
    }

    bool init() {
        std::lock_guard<std::mutex> lk(mu_);
        if (fp_) return true;
        const char* path = std::getenv("NURAFT_TRACE_FILE");
        if (!path || path[0] == '\0') return false;
        fp_ = std::fopen(path, "w");
        return fp_ != nullptr;
    }

    void write(const std::string& line) {
        std::lock_guard<std::mutex> lk(mu_);
        if (!fp_) return;
        std::fwrite(line.data(), 1, line.size(), fp_);
        std::fputc('\n', fp_);
        std::fflush(fp_);
    }

    bool is_open() const { return fp_ != nullptr; }

    void close() {
        std::lock_guard<std::mutex> lk(mu_);
        if (fp_) { std::fclose(fp_); fp_ = nullptr; }
    }

private:
    TraceWriter() : fp_(nullptr) {}
    ~TraceWriter() { close(); }
    TraceWriter(const TraceWriter&) = delete;
    TraceWriter& operator=(const TraceWriter&) = delete;

    std::mutex mu_;
    FILE* fp_;
};

class EventBuilder {
public:
    EventBuilder(const char* event_name, const std::string& nid) {
        buf_.reserve(512);
        buf_ = "{\"tag\":\"trace\",\"ts\":";
        buf_ += std::to_string(now_ns());
        buf_ += ",\"event\":\"";
        buf_ += event_name;
        buf_ += "\",\"nid\":\"";
        buf_ += nid;
        buf_ += "\"";
    }

    EventBuilder& state(uint64_t term, int role,
                        uint64_t commitIdx, uint64_t smCommitIdx,
                        uint64_t precommitIdx,
                        uint64_t lastLogIdx, uint64_t lastLogTerm) {
        buf_ += ",\"state\":{\"term\":";
        buf_ += std::to_string(term);
        buf_ += ",\"role\":\"";
        buf_ += role_to_str(role);
        buf_ += "\",\"commitIndex\":";
        buf_ += std::to_string(commitIdx);
        buf_ += ",\"smCommitIndex\":";
        buf_ += std::to_string(smCommitIdx);
        buf_ += ",\"precommitIndex\":";
        buf_ += std::to_string(precommitIdx);
        buf_ += ",\"lastLogIndex\":";
        buf_ += std::to_string(lastLogIdx);
        buf_ += ",\"lastLogTerm\":";
        buf_ += std::to_string(lastLogTerm);
        buf_ += "}";
        return *this;
    }

    EventBuilder& field_int(const char* key, int64_t val) {
        buf_ += ",\"";
        buf_ += key;
        buf_ += "\":";
        buf_ += std::to_string(val);
        return *this;
    }

    EventBuilder& field_str(const char* key, const std::string& val) {
        buf_ += ",\"";
        buf_ += key;
        buf_ += "\":\"";
        buf_ += val;
        buf_ += "\"";
        return *this;
    }

    EventBuilder& field_bool(const char* key, bool val) {
        buf_ += ",\"";
        buf_ += key;
        buf_ += "\":";
        buf_ += val ? "true" : "false";
        return *this;
    }

    void emit() {
        buf_ += "}";
        TraceWriter::instance().write(buf_);
    }

private:
    std::string buf_;
};

// Helper macros for concise state capture inside raft_server methods.
// These access raft_server member variables directly (id_, state_, role_, etc.)
#define TLA_TRACE_STATE_ARGS \
    state_->get_term(), static_cast<int>(role_.load()), \
    quick_commit_index_.load(), sm_commit_index_.load(), \
    precommit_index_.load(), \
    log_store_->next_slot() - 1, \
    term_for_log(log_store_->next_slot() - 1)

#define TLA_TRACE_NID tla_trace::server_name(id_)

} // namespace tla_trace
} // namespace nuraft

#endif // NURAFT_TLA_TRACE_HXX
