#pragma once
#include "swss/table.h"
namespace swss {
class Select {
public:
    enum { OBJECT, ERROR, TIMEOUT };
    void addSelectable(Selectable*) {}
    int select(Selectable** out, int timeout_ms = -1) { *out = nullptr; return TIMEOUT; }
};
}
