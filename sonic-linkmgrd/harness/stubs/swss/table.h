#pragma once
#include <string>
#include <vector>
#include <deque>
#include <tuple>
#include <utility>
#include <map>
namespace swss {
typedef std::pair<std::string, std::string> FieldValueTuple;
typedef std::tuple<std::string, std::string, std::vector<FieldValueTuple>> KeyOpFieldsValuesTuple;

inline std::string kfvKey(const KeyOpFieldsValuesTuple& kv) { return std::get<0>(kv); }
inline std::string kfvOp(const KeyOpFieldsValuesTuple& kv) { return std::get<1>(kv); }
inline std::vector<FieldValueTuple> kfvFieldsValues(const KeyOpFieldsValuesTuple& kv) { return std::get<2>(kv); }
inline std::string fvField(const FieldValueTuple& fv) { return fv.first; }
inline std::string fvValue(const FieldValueTuple& fv) { return fv.second; }

class Selectable {
public:
    virtual ~Selectable() = default;
};

class DBConnector;
class Table {
public:
    Table() {}
    Table(DBConnector*, const std::string&) {}
    Table(DBConnector*, const char*) {}
    bool get(const std::string&, std::vector<FieldValueTuple>&) { return false; }
    bool hget(const std::string&, const std::string&, std::string&) { return false; }
    void set(const std::string&, const std::vector<FieldValueTuple>&) {}
    void hset(const std::string&, const std::string&, const std::string&) {}
    void del(const std::string&) {}
    void hdel(const std::string&, const std::string&) {}
    void getKeys(std::vector<std::string>&) {}
    void getContent(std::vector<KeyOpFieldsValuesTuple>&) {}
};
}

// Make helpers available in global namespace (SONiC convention)
using swss::kfvKey;
using swss::kfvOp;
using swss::kfvFieldsValues;
using swss::fvField;
using swss::fvValue;
