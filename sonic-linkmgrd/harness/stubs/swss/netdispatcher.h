#pragma once
#include "swss/netmsg.h"
namespace swss {
class NetDispatcher {
public:
    static NetDispatcher& getInstance() { static NetDispatcher d; return d; }
    void registerMessageHandler(int, NetMsg*) {}
};
}
