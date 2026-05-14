#pragma once
#include <string>
namespace swss {
class WarmStart {
public:
    enum WarmStartState { INITIALIZED, RECONCILED, WSDISABLED, WSUNKNOWN };
    static void initialize(const std::string&, const std::string&) {}
    static void checkWarmStart(const std::string&, const std::string& = "", bool = true) {}
    static bool isWarmStart() { return false; }
    static uint32_t getWarmStartTimer(const std::string&, const std::string&) { return 0; }
    static void setWarmStartState(const std::string&, WarmStartState) {}
};
}
