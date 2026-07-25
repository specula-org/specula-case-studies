#pragma once
#include "swss/dbconnector.h"
#include "swss/table.h"
#include <string>
#include <vector>
namespace swss {
class ProducerStateTable : public Selectable {
public:
    ProducerStateTable(DBConnector*, const std::string&) {}
    void set(const std::string&, const std::vector<FieldValueTuple>&) {}
    void del(const std::string&) {}
};
}
