#pragma once

#include <fstream>
#include <iostream>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <chrono>
#include <vector>

namespace tla_trace {

class Emitter {
public:
    static Emitter& getInstance() {
        static Emitter instance;
        return instance;
    }

    void init(const std::string& filename) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (file_.is_open()) {
            file_.close();
        }
        file_.open(filename, std::ios::app);
        if (!file_.is_open()) {
            std::cerr << "Failed to open trace file: " << filename << std::endl;
        }
    }

    void close() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (file_.is_open()) {
            file_.close();
        }
    }

    void emit(const std::string& event_name,
              const std::string& node,
              int64_t term,
              const std::map<std::string, std::string>& fields = {}) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!file_.is_open()) {
            return;
        }

        auto ts = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();

        std::stringstream ss;
        ss << "{\"tag\":\"trace\",\"ts\":" << ts
           << ",\"event\":\"" << event_name << "\""
           << ",\"node\":\"" << node << "\""
           << ",\"term\":" << term;

        for (const auto& [key, value] : fields) {
            ss << ",\"" << key << "\":";
            if (value == "true" || value == "false" ||
                (value[0] >= '0' && value[0] <= '9') ||
                (value[0] == '[' && value[value.length()-1] == ']')) {
                ss << value;  // Direct JSON values
            } else if (value[0] == '"') {
                ss << value;  // Already quoted
            } else {
                ss << "\"" << value << "\"";  // String value
            }
        }
        ss << "}\n";

        file_ << ss.str();
        file_.flush();
    }

private:
    Emitter() = default;
    ~Emitter() { close(); }

    std::ofstream file_;
    std::mutex mutex_;
};

}  // namespace tla_trace
