#pragma once
struct nl_object;
namespace swss {
class NetMsg {
public:
    virtual ~NetMsg() = default;
    virtual void onMsg(int, struct nl_object*) {}
};
}
