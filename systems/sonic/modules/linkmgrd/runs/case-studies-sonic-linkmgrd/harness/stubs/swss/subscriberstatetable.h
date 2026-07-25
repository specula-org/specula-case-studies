#pragma once
#include "swss/dbconnector.h"
#include "swss/table.h"
#include <string>
#include <deque>
namespace swss {
class SubscriberStateTable : public Selectable {
public:
    SubscriberStateTable(DBConnector*, const std::string&) {}
    void pops(std::deque<KeyOpFieldsValuesTuple>&) {}
};
}
