/* TLA+ trace instrumentation implementation for LogCabin Raft.
 *
 * Manual JSON construction — no external library dependency.
 * Thread-safe via mutex around file writes.
 */

#ifdef LOGCABIN_TLA_TRACE

#include "Server/tla_trace.h"

#include <cstring>
#include <cstdlib>

namespace LogCabin {
namespace Server {
namespace TlaTrace {

// ---- Singleton state ----

static std::mutex gMutex;
static FILE* gFile = nullptr;
static std::unordered_map<uint64_t, std::string> gServerMap;
static const std::string gUnknown = "?";

// ---- Helpers ----

static uint64_t nowNanos() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ULL +
           static_cast<uint64_t>(ts.tv_nsec);
}

static void writeJson(FILE* f, const char* json) {
    fputs(json, f);
    fputc('\n', f);
    fflush(f);
}

// Escape a string value for JSON.  Only handles the chars that
// might appear in server IDs and role strings.
static void jsonEscapeAppend(std::string& out, const char* s) {
    out += '"';
    for (; *s; ++s) {
        switch (*s) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            default:   out += *s;
        }
    }
    out += '"';
}

// ---- Public API ----

int init(const char* filepath) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (gFile != nullptr)
        return 0; // already open — skip re-open to prevent truncation
    gFile = fopen(filepath, "w");
    return gFile ? 0 : -1;
}

void registerServer(uint64_t implId, const std::string& tlaId) {
    std::lock_guard<std::mutex> lock(gMutex);
    gServerMap[implId] = tlaId;
}

const std::string& nid(uint64_t implId) {
    std::lock_guard<std::mutex> lock(gMutex);
    auto it = gServerMap.find(implId);
    if (it != gServerMap.end())
        return it->second;
    return gUnknown;
}

bool isEnabled() {
    std::lock_guard<std::mutex> lock(gMutex);
    return gFile != nullptr;
}

void emitCrash(uint64_t nodeId) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gFile) return;

    std::string line;
    line.reserve(256);
    line += "{\"tag\":\"trace\",\"event\":\"Crash\",\"node\":";
    jsonEscapeAppend(line, nid(nodeId).c_str());
    line += ",\"timestamp\":";
    line += std::to_string(nowNanos());
    line += "}";
    writeJson(gFile, line.c_str());
}

void close() {
    std::lock_guard<std::mutex> lock(gMutex);
    if (gFile) {
        fclose(gFile);
        gFile = nullptr;
    }
}

// ---- Event builder ----

Event::Event(const char* name, uint64_t nodeId)
    : name_(name)
    , nodeId_(nodeId)
    , hasState_(false)
    , currentTerm_(0)
    , role_("follower")
    , commitIndex_(0)
    , lastLogIndex_(0)
    , lastLogTerm_(0)
    , nfields_(0)
{
}

Event& Event::state(uint64_t currentTerm, const char* role,
                     uint64_t commitIndex, uint64_t lastLogIndex,
                     uint64_t lastLogTerm) {
    hasState_ = true;
    currentTerm_ = currentTerm;
    role_ = role;
    commitIndex_ = commitIndex;
    lastLogIndex_ = lastLogIndex;
    lastLogTerm_ = lastLogTerm;
    return *this;
}

Event& Event::field(const char* key, const std::string& val) {
    if (nfields_ < MAX_FIELDS) {
        fields_[nfields_].key = key;
        fields_[nfields_].type = Field::STRING;
        fields_[nfields_].sval = val;
        nfields_++;
    }
    return *this;
}

Event& Event::field(const char* key, const char* val) {
    if (nfields_ < MAX_FIELDS) {
        fields_[nfields_].key = key;
        fields_[nfields_].type = Field::STRING;
        fields_[nfields_].sval = val;
        nfields_++;
    }
    return *this;
}

Event& Event::field(const char* key, uint64_t val) {
    if (nfields_ < MAX_FIELDS) {
        fields_[nfields_].key = key;
        fields_[nfields_].type = Field::UINT;
        fields_[nfields_].uval = val;
        nfields_++;
    }
    return *this;
}

Event& Event::field(const char* key, bool val) {
    if (nfields_ < MAX_FIELDS) {
        fields_[nfields_].key = key;
        fields_[nfields_].type = Field::BOOL;
        fields_[nfields_].bval = val;
        nfields_++;
    }
    return *this;
}

void Event::emit() {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gFile) return;

    std::string line;
    line.reserve(512);

    // Envelope
    line += "{\"tag\":\"trace\",\"event\":";
    jsonEscapeAppend(line, name_);
    line += ",\"node\":";
    {
        auto it = gServerMap.find(nodeId_);
        if (it != gServerMap.end())
            jsonEscapeAppend(line, it->second.c_str());
        else
            jsonEscapeAppend(line, "?");
    }
    line += ",\"timestamp\":";
    line += std::to_string(nowNanos());

    // State block
    if (hasState_) {
        line += ",\"state\":{\"currentTerm\":";
        line += std::to_string(currentTerm_);
        line += ",\"role\":";
        jsonEscapeAppend(line, role_);
        line += ",\"commitIndex\":";
        line += std::to_string(commitIndex_);
        line += ",\"lastLogIndex\":";
        line += std::to_string(lastLogIndex_);
        line += ",\"lastLogTerm\":";
        line += std::to_string(lastLogTerm_);
        line += "}";
    }

    // Extra fields
    for (int i = 0; i < nfields_; i++) {
        line += ",";
        jsonEscapeAppend(line, fields_[i].key);
        line += ":";
        switch (fields_[i].type) {
            case Field::STRING:
                jsonEscapeAppend(line, fields_[i].sval.c_str());
                break;
            case Field::UINT:
                line += std::to_string(fields_[i].uval);
                break;
            case Field::BOOL:
                line += fields_[i].bval ? "true" : "false";
                break;
        }
    }

    line += "}";
    writeJson(gFile, line.c_str());
}

} // namespace TlaTrace
} // namespace Server
} // namespace LogCabin

#endif // LOGCABIN_TLA_TRACE
