#pragma once
#include <string>
namespace swss {
class LinkCache {
public:
    static LinkCache& getInstance() { static LinkCache c; return c; }
    std::string ifindexToName(int) { return ""; }
};
}
