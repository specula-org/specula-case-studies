#pragma once
#include <string>
#include "swss/schema.h"
namespace swss {
class DBConnector {
public:
    DBConnector(const std::string&, unsigned int) {}
    DBConnector(int, const std::string&, unsigned int) {}
};
}
