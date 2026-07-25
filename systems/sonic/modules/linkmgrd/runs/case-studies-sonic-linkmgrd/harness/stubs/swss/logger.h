#pragma once
#include <string>
#include <map>
#include <functional>
namespace swss {
class Logger {
public:
    enum Priority {
        SWSS_EMERG, SWSS_ALERT, SWSS_CRIT, SWSS_ERROR,
        SWSS_WARN, SWSS_NOTICE, SWSS_INFO, SWSS_DEBUG
    };
    static Logger& getInstance() { static Logger l; return l; }
    static Priority getMinPrio() { return SWSS_DEBUG; }
    void write(Priority, const char*) {}
    void setMinPrio(Priority) {}
    // Variadic template to accept any combination of arguments
    template<typename... Args>
    static void linkToDbWithOutput(Args&&...) {}
    static void restartLogger() {}
    static std::map<std::string, Priority> priorityStringMap;
};
}
