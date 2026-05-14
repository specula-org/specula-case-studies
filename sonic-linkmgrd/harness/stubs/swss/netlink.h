#pragma once
#include "swss/table.h"
#include <linux/rtnetlink.h>
namespace swss {
class NetLink : public Selectable {
public:
    void registerGroup(int) {}
    void dumpRequest(int) {}
};
}
