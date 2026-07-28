#ifndef OPENCBDC_TX_SPECULA_TLA_TRACE_H_
#define OPENCBDC_TX_SPECULA_TLA_TRACE_H_

#include <atomic>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <mutex>
#include <string>

namespace cbdc::specula {

    class trace_emitter {
      public:
        static trace_emitter& get();

        bool init(const std::string& path, const std::string& node_label);
        void shutdown();

        void emit(const std::string& event,
                  const std::string& node,
                  const std::string& dtx_id,
                  const std::string& tx_id,
                  const std::string& state_json);

        auto is_initialized() const -> bool;

      private:
        trace_emitter() = default;
        ~trace_emitter();
        trace_emitter(const trace_emitter&) = delete;
        auto operator=(const trace_emitter&) -> trace_emitter& = delete;

        std::mutex m_mut;
        std::ofstream m_out;
        std::string m_node_label;
        std::atomic<bool> m_initialized{false};
    };

    inline std::string bool_to_str(bool v) {
        return v ? "true" : "false";
    }

    inline std::string json_esc(const std::string& s) {
        std::string out;
        out += '"';
        for(auto c : s) {
            if(c == '"') {
                out += "\\\"";
            } else if(c == '\\') {
                out += "\\\\";
            } else if(c == '\n') {
                out += "\\n";
            } else {
                out += c;
            }
        }
        out += '"';
        return out;
    }

    inline std::string kv(const std::string& k, const std::string& v) {
        return json_esc(k) + ":" + v;
    }

    inline std::string kv_str(const std::string& k, const std::string& v) {
        return json_esc(k) + ":" + json_esc(v);
    }

    inline std::string kv_bool(const std::string& k, bool v) {
        return json_esc(k) + ":" + bool_to_str(v);
    }

    inline std::string kv_int(const std::string& k, uint64_t v) {
        return json_esc(k) + ":" + std::to_string(v);
    }

    template<typename... Fields>
    inline std::string obj(Fields&&... fields) {
        std::string out = "{";
        bool first = true;
        auto append = [&](const std::string& f) {
            if(!first) {
                out += ",";
            }
            first = false;
            out += f;
        };
        (append(std::forward<Fields>(fields)), ...);
        out += "}";
        return out;
    }

}

#define SPECULA_EMIT(event, node, dtx_id, tx_id, state_json) \
    do { \
        ::cbdc::specula::trace_emitter::get().emit( \
            (event), (node), (dtx_id), (tx_id), (state_json)); \
    } while(0)

#endif
