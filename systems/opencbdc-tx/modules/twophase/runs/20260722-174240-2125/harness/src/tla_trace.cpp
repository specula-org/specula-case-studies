#include "tla_trace.hpp"

#include <iostream>

namespace cbdc::specula {

    trace_emitter& trace_emitter::get() {
        static trace_emitter instance;
        return instance;
    }

    bool trace_emitter::init(const std::string& path,
                              const std::string& node_label) {
        std::lock_guard<std::mutex> l(m_mut);
        if(m_initialized) {
            return false;
        }
        m_out.open(path, std::ios::out);
        if(!m_out.is_open()) {
            std::cerr << "[tla_trace] Failed to open: " << path << std::endl;
            return false;
        }
        m_node_label = node_label;
        m_initialized = true;
        auto ts = std::chrono::duration_cast<std::chrono::nanoseconds>(
                      std::chrono::high_resolution_clock::now()
                          .time_since_epoch())
                      .count();
        m_out << "{\"tag\":\"config\",\"ts\":" << ts
              << ",\"config\":{\"servers\":[\"c1\",\"s1\",\"sentinel0\"]}}\n";
        m_out.flush();
        return true;
    }

    void trace_emitter::shutdown() {
        std::lock_guard<std::mutex> l(m_mut);
        if(m_initialized) {
            m_out.close();
            m_initialized = false;
        }
    }

    trace_emitter::~trace_emitter() {
        shutdown();
    }

    auto trace_emitter::is_initialized() const -> bool {
        return m_initialized.load();
    }

    void trace_emitter::emit(const std::string& event,
                              const std::string& node,
                              const std::string& dtx_id,
                              const std::string& tx_id,
                              const std::string& state_json) {
        if(!m_initialized) {
            return;
        }
        auto ts = std::chrono::duration_cast<std::chrono::nanoseconds>(
                      std::chrono::high_resolution_clock::now()
                          .time_since_epoch())
                      .count();
        std::lock_guard<std::mutex> l(m_mut);
        m_out << "{\"tag\":\"trace\",\"ts\":" << ts
              << ",\"event\":{\"name\":" << json_esc(event)
              << ",\"nid\":" << json_esc(node);
        if(!dtx_id.empty()) {
            m_out << ",\"dtx_id\":" << json_esc(dtx_id);
        }
        if(!tx_id.empty()) {
            m_out << ",\"tx_id\":" << json_esc(tx_id);
        }
        m_out << ",\"state\":" << state_json;
        m_out << "}}\n";
        m_out.flush();
    }

}
