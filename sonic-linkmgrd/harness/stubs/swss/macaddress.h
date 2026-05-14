#pragma once
#include <string>
#include <cstring>
namespace swss {
class MacAddress {
public:
    MacAddress() { memset(m_mac, 0, 6); }
    MacAddress(const std::string&) { memset(m_mac, 0, 6); }
    const uint8_t* getMac() const { return m_mac; }
private:
    uint8_t m_mac[6];
};
}
